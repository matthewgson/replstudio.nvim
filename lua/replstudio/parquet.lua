--- Read-only parquet viewer: opening a *.parquet file shows its rows as an
--- aligned table instead of binary.
---
--- The buffer holds a window of the table, not the table: up to SPAN chunks of
--- rows around the view, and up to BAND columns. Moving near an edge
--- of the window fetches the next chunk in the background and drops chunks far
--- behind, so any file behaves like a small one. Parquet stores columns
--- separately and DuckDB skips whole row groups for `OFFSET`, so a fetch costs
--- about the same anywhere in any file. A file that fits in the window is read
--- once and never again.
---
--- Buffer layout: three header lines (names, types, rule), then one line per
--- loaded row. A non-focusable float pinned over the window's top lines repeats
--- the header, following horizontal scroll, so names and types stay visible.
--- Row numbers live in 'statuscolumn' (offset by b:replstudio_r0, the rows
--- above the window), which does not scroll sideways. NULLs are highlighted by
--- a decoration provider, only on lines being drawn.

local config = require("replstudio.config")

local api = vim.api
local M = {}

local HEADER = 3
local SEP = " │ " -- 5 bytes, 3 columns
local SEP_W = 3
local NULL = "\1"
-- rows = "auto": a fetch holds about this many cells. Parsing and layout run
-- on the main thread at roughly 0.5 µs a cell, so a fetch costs a frame or so.
local CELLS, MIN_ROWS, MAX_ROWS = 20000, 100, 5000
-- Columns per horizontal fetch, columns kept, and columns read on open.
local COLS, BAND, OPEN_COLS = 10, 60, 40
-- Row chunks kept.
local SPAN = 3
-- Characters read per cell: far more than a column shows, and it keeps long
-- text (JSON, documents) from flooding a fetch. K reads the rest on demand.
local CELL_CHARS = 256

--- Cells as text, with the output's own field/record separators (\31, \30)
--- shown as ␟ ␞, so a value holding them cannot shift the rows.
---@param cols string a COLUMNS(...) expression
---@param full? boolean whole values; else cut to CELL_CHARS
---@return string
local function as_text(cols, full)
  local e = ("%s::VARCHAR"):format(cols)
  if not full then
    e = ("left(%s, %d)"):format(e, CELL_CHARS) -- cut first: less to translate
  end
  return ("translate(%s, chr(30) || chr(31), '␞␟')"):format(e)
end
-- Fetch when fewer than this many chunks of rows (plus a screen), or
-- screens of columns, remain past the view.
local PREFETCH = 1
-- Main-thread time per slice while preparing a fetched chunk; the rest waits
-- for the next turn of the event loop, so keys and redraws are never held up.
local SLICE_NS = 4e6
local ns = api.nvim_create_namespace("replstudio.parquet")
local ns_null = api.nvim_create_namespace("replstudio.parquet.null")
local group = api.nvim_create_augroup("replstudio.parquet", { clear = true })

---@class replstudio.ParquetView
---@field path string
---@field cols { name: string, type: string, kind: string }[] every column
---@field heads table[] cleaned { name, width, type, width } per column
---@field right boolean[] right-align the column (numbers)
---@field total integer rows in the file
---@field chunk integer rows per fetch
---@field widths table<integer, integer> fixed once a column is first read
---@field r1 integer first loaded row
---@field r2 integer last loaded row
---@field c1 integer first loaded column
---@field c2 integer last loaded column
---@field raw table<integer, table<integer, string>> raw values by row, column
---@field cells table<integer, table<integer, string>> laid-out cell text
---@field nulls table<integer, true> rows that may hold a NULL
---@field starts integer[] display column of each loaded column (from c1)
---@field bandw integer display width of a loaded line
---@field token table|nil the fetch whose result is wanted
---@field loading boolean
---@field stalled boolean the last fetch failed; stop prefetching
---@field hbuf integer header buffer shown in the floats
---@field floats table<integer, integer> viewer window -> header float

---@type table<integer, replstudio.ParquetView>
local views = {}

-- ── highlights ──────────────────────────────────────────────────────────────

local links = {
  ReplStudioParquetName = "Title",
  ReplStudioParquetSep = "NonText",
  ReplStudioParquetNull = "Comment",
  ReplStudioParquetNum = "Number",
  ReplStudioParquetStr = "String",
  ReplStudioParquetTime = "Special",
  ReplStudioParquetBool = "Boolean",
  ReplStudioParquetNested = "Structure",
  ReplStudioParquetOther = "Type",
}

local function set_highlights()
  for name, link in pairs(links) do
    api.nvim_set_hl(0, name, { link = link, default = true })
  end
end
set_highlights()
api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_highlights })

local kind_hl = {
  num = "ReplStudioParquetNum",
  str = "ReplStudioParquetStr",
  time = "ReplStudioParquetTime",
  bool = "ReplStudioParquetBool",
  nested = "ReplStudioParquetNested",
  other = "ReplStudioParquetOther",
}

---@param t string DuckDB type, e.g. "BIGINT", "DECIMAL(18,2)", "VARCHAR[]"
---@return string
function M._kind(t)
  if t:find("%]$") or t:find("^STRUCT") or t:find("^MAP") or t:find("^UNION") then
    return "nested"
  elseif t:find("^DECIMAL") or t == "FLOAT" or t == "DOUBLE" or (t:find("INT") and t ~= "INTERVAL") then
    return "num"
  elseif t == "BOOLEAN" then
    return "bool"
  elseif t:find("^DATE") or t:find("^TIME") or t == "INTERVAL" then
    return "time"
  elseif t == "VARCHAR" or t == "BLOB" or t == "UUID" or t:find("^ENUM") then
    return "str"
  end
  return "other"
end

-- ── cell text ───────────────────────────────────────────────────────────────

local controls = { ["\n"] = "↵", ["\r"] = "", ["\t"] = "→" }

--- Cell text on one line, and its display width.
---@param v string
---@return string, integer
local function clean(v)
  if not v:find("[%c\128-\255]") then
    return v, #v -- plain ASCII: the common case
  end
  if v:find("%c") then
    v = v:gsub("%c", function(c)
      return controls[c] or "·"
    end)
  end
  if v:find("[\128-\255]") then
    return v, api.nvim_strwidth(v)
  end
  return v, #v
end

---@param v string raw value or NULL
---@return string, integer
local function cell(v)
  if v == NULL then
    return "NULL", 4
  end
  return clean(v)
end

--- Runs of n spaces, made once.
local pads = setmetatable({}, {
  __index = function(t, n)
    local s = (" "):rep(n)
    t[n] = s
    return s
  end,
})

--- Fit `s` (display width `w`) into exactly `width` columns.
---@param s string
---@param w integer
---@param width integer
---@param right boolean
---@return string
local function fit(s, w, width, right)
  if w > width then
    if #s == w then
      s = s:sub(1, width - 1)
    else
      -- Each character takes at least one cell: keep `width` of them, then
      -- trim from the end (a long cell would otherwise cost O(n²)).
      s = vim.fn.strcharpart(s, 0, width)
      local n = vim.fn.strchars(s)
      while api.nvim_strwidth(s) > width - 1 do
        n = n - 1
        s = vim.fn.strcharpart(s, 0, n)
      end
    end
    s = s .. "…"
    w = api.nvim_strwidth(s)
  end
  if w == width then
    return s
  end
  local pad = pads[width - w]
  return right and pad .. s or s .. pad
end

-- ── table layout ────────────────────────────────────────────────────────────

---@param view replstudio.ParquetView
local function init_heads(view)
  view.heads, view.right = {}, {}
  for j, c in ipairs(view.cols) do
    view.right[j] = c.kind == "num"
    -- Names and types can hold newlines or wide characters too.
    local name, nw = clean(c.name)
    local type, tw = clean(c.type)
    view.heads[j] = { name, nw, type, tw }
  end
end

--- Fix the widths of columns `j1..j2` that have none yet, from their header
--- and `rows` (values for `j1..j2`).
---@param view replstudio.ParquetView
---@param rows string[][]
---@param j1 integer
---@param j2 integer
local function measure(view, rows, j1, j2)
  local max = config.parquet.max_width
  for j = j1, j2 do
    if not view.widths[j] then
      local h, k = view.heads[j], j - j1 + 1
      local w = math.max(h[2], h[4], 4)
      for _, row in ipairs(rows) do
        if w >= max then
          break
        end
        local _, cw = cell(row[k])
        w = math.max(w, cw)
      end
      view.widths[j] = math.min(max, w)
    end
  end
end

--- Store row `r`'s values for columns `j1..` and lay them out.
---@param view replstudio.ParquetView
---@param r integer
---@param j1 integer
---@param values string[]
local function store(view, r, j1, values)
  local raw, cells = view.raw[r] or {}, view.cells[r] or {}
  local widths, right = view.widths, view.right
  for k = 1, #values do
    local j, v = j1 + k - 1, values[k]
    local s, w
    if v == NULL then
      s, w = "NULL", 4
      view.nulls[r] = true
    else
      s, w = clean(v)
    end
    raw[j], cells[j] = v, fit(s, w, widths[j], right[j])
  end
  view.raw[r], view.cells[r] = raw, cells
end

---@param view replstudio.ParquetView
---@param r integer
---@return string
local function row_line(view, r)
  local cells, parts = view.cells[r], {}
  for j = view.c1, view.c2 do
    parts[#parts + 1] = cells[j]
  end
  return " " .. table.concat(parts, SEP)
end

--- NULL highlight spans { byte start, byte end } on row `r`'s line.
---@param view replstudio.ParquetView
---@param r integer
---@return integer[][]
local function null_spans(view, r)
  local spans = {}
  if not view.nulls[r] then
    return spans
  end
  local raw, cells, b = view.raw[r], view.cells[r], 1
  for j = view.c1, view.c2 do
    local s = cells[j]
    if raw[j] == NULL then
      local off = view.cols[j].kind == "num" and #s - 4 or 0
      spans[#spans + 1] = { b + off, b + off + 4 }
    end
    b = b + #s + #SEP
  end
  return spans
end

--- Header lines and their highlight spans for the loaded columns; sets
--- `view.starts` and `view.bandw`.
---@param view replstudio.ParquetView
---@return string[] lines
---@return table marks { row, byte start, byte end, group }
local function header(view)
  local names, types, rule, marks, starts = {}, {}, {}, {}, {}
  local at, nb, tb = 1, 1, 1 -- display column, byte offsets (leading space)
  for j = view.c1, view.c2 do
    local h, w = view.heads[j], view.widths[j]
    local name = fit(h[1], h[2], w, false)
    local type = fit(h[3], h[4], w, false)
    marks[#marks + 1] = { 0, nb, nb + #name, "ReplStudioParquetName" }
    marks[#marks + 1] = { 1, tb, tb + #type, kind_hl[view.cols[j].kind] }
    names[#names + 1], types[#types + 1], rule[#rule + 1] = name, type, ("─"):rep(w)
    starts[#starts + 1] = at
    at = at + w + SEP_W
    nb, tb = nb + #name + #SEP, tb + #type + #SEP
  end
  view.starts, view.bandw = starts, at - SEP_W
  return {
    " " .. table.concat(names, SEP),
    " " .. table.concat(types, SEP),
    "─" .. table.concat(rule, "─┼─"),
  }, marks
end

--- Lay out a whole small table (every row and column) at once.
---@param view { cols: table[], rows: string[][] }
---@return string[] lines
---@return table marks
function M._layout(view)
  ---@cast view replstudio.ParquetView
  view.widths, view.raw, view.cells, view.nulls = {}, {}, {}, {}
  view.c1, view.c2, view.r1, view.r2 = 1, #view.cols, 1, #view.rows
  init_heads(view)
  measure(view, view.rows, 1, #view.cols)
  for r, row in ipairs(view.rows) do
    store(view, r, 1, row)
  end
  local lines, marks = header(view)
  for r = 1, #view.rows do
    lines[#lines + 1] = row_line(view, r)
    for _, s in ipairs(null_spans(view, r)) do
      marks[#marks + 1] = { HEADER + r - 1, s[1], s[2], "ReplStudioParquetNull" }
    end
  end
  return lines, marks
end

-- ── duckdb ──────────────────────────────────────────────────────────────────

---@param s string
---@return string
local function quote(s)
  return "'" .. s:gsub("'", "''") .. "'"
end

--- A file path as a SQL literal; [ * ? are escaped so DuckDB does not read
--- the path as a glob and open a different file.
---@param path string
---@return string
local function quote_path(path)
  return quote((path:gsub("[%[%*%?]", "[%0]")))
end

--- Rows per fetch for a table of `ncol` columns.
---@param ncol integer
---@return integer
function M._chunk(ncol)
  local rows = config.parquet.rows
  if type(rows) == "number" then
    return math.max(1, math.floor(rows))
  end
  return math.max(MIN_ROWS, math.min(MAX_ROWS, math.floor(CELLS / math.max(math.min(ncol, BAND), 1))))
end

--- Row count, schema, and the first `limit` rows of the first OPEN_COLS
--- columns. `limit` "auto" sizes it from the column count in the same query.
--- The schema is read once into a temp table: reading it costs ~15 ms a time
--- on a file with thousands of columns.
---@param path string
---@param limit integer|string
---@return string
function M._sql(path, limit)
  local f = quote_path(path)
  local n = type(limit) == "number" and tostring(limit)
    or ("(SELECT greatest(%d, least(%d, %d // least(greatest(count(*), 1), %d))) FROM schema)"):format(
      MIN_ROWS,
      MAX_ROWS,
      CELLS,
      BAND
    )
  return table.concat({
    "SET parquet_metadata_cache = true;",
    ("CREATE TEMP TABLE schema AS SELECT column_name, column_type FROM (DESCRIBE SELECT * FROM %s);"):format(f),
    ("SELECT count(*), (SELECT count(*) FROM schema) FROM %s;"):format(f),
    "SELECT * FROM schema;",
    ("SET VARIABLE replstudio_cols = (SELECT list(column_name)[1:%d] FROM schema);"):format(OPEN_COLS),
    ("SELECT %s FROM %s LIMIT %s;"):format(as_text("COLUMNS(getvariable('replstudio_cols'))"), f, n),
  }, "\n")
end

--- `limit` rows after the first `offset`, of the named columns, each cell
--- cut to CELL_CHARS characters (`full`: whole values).
---@param path string
---@param names string[]
---@param limit integer
---@param offset integer
---@param full? boolean
---@return string
function M._tile_sql(path, names, limit, offset, full)
  local cols = ("COLUMNS([%s])"):format(table.concat(vim.tbl_map(quote, names), ", "))
  return ("SELECT %s FROM %s LIMIT %d OFFSET %d;"):format(as_text(cols, full), quote_path(path), limit, offset)
end

--- Split on a one-byte separator; several times faster than vim.split.
---@param str string
---@param sep string
---@return string[]
local function split(str, sep)
  local t, n, i = {}, 0, 1
  while true do
    local j = str:find(sep, i, true)
    n = n + 1
    if not j then
      t[n] = str:sub(i)
      return t
    end
    t[n] = str:sub(i, j - 1)
    i = j + 1
  end
end

---@param records string[]
---@param from integer
---@return string[][]
local function split_rows(records, from)
  local rows = {}
  for i = from, #records do
    rows[#rows + 1] = split(records[i], "\31")
  end
  return rows
end

---@param out string
---@return string[]
local function split_records(out)
  local records = split(out, "\30")
  if records[#records] == "" then
    records[#records] = nil
  end
  return records
end

--- Parse `duckdb -list` output (fields \31, records \30, NULL \1).
---@param out string
---@return { total: integer, cols: table[], rows: string[][] }|nil
function M._parse(out)
  local records = split_records(out)
  local head = split(records[1] or "", "\31")
  local total, ncol = tonumber(head[1]), tonumber(head[2])
  if not total or not ncol then
    return nil
  end
  local cols = {}
  for i = 2, ncol + 1 do
    local f = split(records[i], "\31")
    cols[#cols + 1] = { name = f[1], type = f[2]:lower(), kind = M._kind(f[2]) }
  end
  return { total = total, cols = cols, rows = split_rows(records, ncol + 2) }
end

---@param sql string
---@return string[]
local function duckdb(sql)
  return {
    "duckdb",
    "-init",
    vim.fn.has("win32") == 1 and "NUL" or "/dev/null", -- skip ~/.duckdbrc
    "-batch",
    "-noheader",
    "-list",
    "-separator",
    "\31",
    "-newline",
    "\30",
    "-nullvalue",
    NULL,
    "-c",
    sql,
  }
end

-- ── header float ────────────────────────────────────────────────────────────

--- Last applied { width, textoff, leftcol } per header float.
local synced = {} ---@type table<integer, integer[]>

local function close_float(view, win)
  local f = view.floats[win]
  view.floats[win] = nil
  if f then
    synced[f] = nil
  end
  if f and api.nvim_win_is_valid(f) then
    api.nvim_win_close(f, true)
  end
end

--- Create or realign the header float over `win` to match its width and
--- horizontal scroll.
---@param view replstudio.ParquetView
---@param win integer
local function sync_float(view, win)
  local info = vim.fn.getwininfo(win)[1]
  if not info or info.height <= HEADER then
    return close_float(view, win)
  end
  local f = view.floats[win]
  local leftcol = api.nvim_win_call(win, vim.fn.winsaveview).leftcol
  local last = f and synced[f]
  if last and last[1] == info.width and last[2] == info.textoff and last[3] == leftcol and api.nvim_win_is_valid(f) then
    return -- plain vertical scroll: nothing to do
  end
  local cfg = {
    relative = "win",
    win = win,
    row = 0,
    col = 0,
    width = info.width,
    height = HEADER,
    focusable = false,
    style = "minimal",
    zindex = 10,
  }
  if not (f and api.nvim_win_is_valid(f)) then
    cfg.noautocmd = true
    f = api.nvim_open_win(view.hbuf, false, cfg)
    view.floats[win] = f
    vim.wo[f].winhighlight = "NormalFloat:Normal"
    vim.wo[f].wrap = false
  else
    api.nvim_win_set_config(f, cfg)
  end
  -- Same left margin as the viewer, blank, so the columns line up.
  vim.wo[f].statuscolumn = (" "):rep(info.textoff)
  api.nvim_win_call(f, function()
    vim.fn.winrestview({ topline = 1, lnum = 1, col = 0, leftcol = leftcol })
  end)
  synced[f] = { info.width, info.textoff, leftcol }
end

--- Close floats whose window closed or no longer shows its viewer.
local function prune()
  for buf, view in pairs(views) do
    for win in pairs(view.floats) do
      if not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= buf then
        close_float(view, win)
      end
    end
  end
end

-- ── window ──────────────────────────────────────────────────────────────────

---@param n integer
---@return string
local function commas(n)
  local s = tostring(n)
  repeat
    local k
    s, k = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
  until k == 0
  return s
end

--- Loaded column index (1-based from c1) at display column `vc` (0-based).
---@param view replstudio.ParquetView
---@param vc integer
---@return integer
local function col_at_vcol(view, vc)
  local k = 1
  for i, s in ipairs(view.starts) do
    if s <= vc then
      k = i
    end
  end
  return k
end

---@param view replstudio.ParquetView
---@param win integer
---@return string
local function winbar(view, win)
  local name = vim.fn.fnamemodify(view.path, ":t"):gsub("%%", "%%%%")
  local cols = ("%d cols"):format(#view.cols)
  if #view.cols > view.c2 - view.c1 + 1 and #view.starts > 0 then
    -- Wide table: which columns are on screen.
    local info = vim.fn.getwininfo(win)[1]
    local left = api.nvim_win_call(win, vim.fn.winsaveview).leftcol
    local a = view.c1 + col_at_vcol(view, left + 1) - 1
    local b = view.c1 + col_at_vcol(view, left + info.width - info.textoff - 1) - 1
    cols = ("cols %s–%s of %s"):format(commas(a), commas(b), commas(#view.cols))
  end
  return ("%%#ReplStudioParquetName# 󰓫 %s %%#Comment# %s rows × %s%%=%%<K cell · w/b column · q close "):format(
    name,
    commas(view.total),
    cols
  )
end

--- Window-local options for a window showing the viewer.
---@param buf integer
---@param win integer
local function setup_win(buf, win)
  local view = views[buf]
  local wo = vim.wo[win][0]
  wo.wrap = false
  wo.list = false
  wo.spell = false
  wo.cursorline = true
  wo.cursorcolumn = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.number = true
  wo.relativenumber = false
  wo.numberwidth = #tostring(view and view.total or 0) + 2
  wo.statuscolumn = "%=%{v:lnum>" .. HEADER .. "?v:lnum-" .. HEADER .. "+get(b:,'replstudio_r0',0):''} "
  wo.scrolloff = math.max(vim.o.scrolloff, HEADER)
  wo.sidescrolloff = 0
  wo.winbar = view and view.cols and winbar(view, win) or ""
  if view and view.cols then
    sync_float(view, win)
  end
end

--- Where the windows on `buf` look, in table coordinates: the topmost and
--- bottommost rows shown, the leftmost and rightmost display columns, and
--- the tallest and widest text area. nil when no window shows it.
---@param view replstudio.ParquetView
---@param buf integer
---@return { top: integer, bot: integer, left: integer, right: integer, h: integer, w: integer }|nil
local function seen(view, buf)
  local s
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local info = vim.fn.getwininfo(win)[1]
    local v = api.nvim_win_call(win, vim.fn.winsaveview)
    local w = info.width - info.textoff
    local top = view.r1 + math.max(math.min(info.topline, v.lnum) - HEADER, 1) - 1
    local bot = view.r1 + math.max(info.botline, v.lnum) - HEADER - 1
    s = s or { top = top, bot = bot, left = v.leftcol, right = v.leftcol + w, h = info.height, w = w }
    s.top, s.bot = math.min(s.top, top), math.max(s.bot, bot)
    s.left, s.right = math.min(s.left, v.leftcol), math.max(s.right, v.leftcol + w)
    s.h, s.w = math.max(s.h, info.height), math.max(s.w, w)
  end
  return s
end

-- ── buffer ──────────────────────────────────────────────────────────────────

---@param buf integer
---@param fn fun()
local function modify(buf, fn)
  vim.bo[buf].modifiable = true
  fn()
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

---@param buf integer
---@param lines string[]
local function set_lines(buf, lines)
  modify(buf, function()
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end)
end

---@param buf integer
---@param marks table
local function apply_marks(buf, marks)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
end

local function sep_syntax(buf)
  api.nvim_buf_call(buf, function()
    vim.cmd([[syntax match ReplStudioParquetSep /[│┼─]/]])
  end)
end

--- Run `fn`, which edits the buffer, then keep each window on `buf` looking
--- at the same table cells: shifted by `dl` lines and `dc` display columns.
---@param buf integer
---@param dl integer
---@param dc integer
---@param fn fun()
local function keep_view(buf, dl, dc, fn)
  local saved = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    saved[win] = api.nvim_win_call(win, function()
      local v = vim.fn.winsaveview()
      v.vcol = vim.fn.virtcol(".")
      return v
    end)
  end
  fn()
  local last = api.nvim_buf_line_count(buf)
  for win, v in pairs(saved) do
    api.nvim_win_call(win, function()
      local leftcol = math.max(0, v.leftcol + dc)
      local topline = math.max(1, math.min(last, v.topline + dl))
      vim.fn.winrestview({
        topline = topline,
        lnum = math.max(math.min(HEADER + 1, last), math.min(last, v.lnum + dl)),
        col = 0,
        leftcol = leftcol,
      })
      vim.cmd("normal! " .. math.max(1, v.vcol + dc) .. "|")
      vim.fn.winrestview({ topline = topline, leftcol = leftcol })
    end)
  end
end

--- Redraw the header and every loaded row (after the columns changed).
---@param buf integer
---@param view replstudio.ParquetView
---@param body? string[] the row lines, if already laid out
local function rebuild(buf, view, body)
  local lines, marks = header(view)
  if body then
    vim.list_extend(lines, body)
  else
    for r = view.r1, view.r2 do
      lines[#lines + 1] = row_line(view, r)
    end
  end
  set_lines(buf, lines)
  apply_marks(buf, marks)

  -- Header buffer for the floats: the same three lines and highlights.
  if not (view.hbuf and api.nvim_buf_is_valid(view.hbuf)) then
    view.hbuf = api.nvim_create_buf(false, true)
    vim.bo[view.hbuf].bufhidden = "hide"
    sep_syntax(view.hbuf)
  end
  local hb = view.hbuf
  vim.bo[hb].modifiable = true
  api.nvim_buf_set_lines(hb, 0, -1, false, vim.list_slice(lines, 1, HEADER))
  vim.bo[hb].modifiable = false
  apply_marks(hb, marks)
end

---@param view replstudio.ParquetView
---@param r1 integer
---@param r2 integer
local function forget_rows(view, r1, r2)
  for r = r1, r2 do
    view.raw[r], view.cells[r], view.nulls[r] = nil, nil, nil
  end
end

---@param view replstudio.ParquetView
---@param j1 integer
---@param j2 integer
local function forget_cols(view, j1, j2)
  for r = view.r1, view.r2 do
    local raw, cells = view.raw[r], view.cells[r]
    for j = j1, j2 do
      raw[j], cells[j] = nil, nil
    end
  end
end

---@param view replstudio.ParquetView
---@param j1 integer
---@param j2 integer
---@return integer display width of columns j1..j2 with their separators
local function span_width(view, j1, j2)
  local w = 0
  for j = j1, j2 do
    w = w + view.widths[j] + SEP_W
  end
  return w
end

-- ── fetching ────────────────────────────────────────────────────────────────

--- Run `fn(i)` for i = 1..n a slice at a time, yielding to the event loop
--- between slices so keys and redraws are never held up; then `done()`.
--- Stops quietly once `alive()` is false; an error goes to `fail`.
---@param n integer
---@param fn fun(i: integer)
---@param alive fun(): boolean
---@param done fun()
---@param fail fun(err: string)
local function sliced(n, fn, alive, done, fail)
  local i = 1
  local function work()
    if not alive() then
      return
    end
    local ok, err = pcall(function()
      local stop = vim.uv.hrtime() + SLICE_NS
      while i <= n do
        fn(i)
        i = i + 1
        if i % 32 == 0 and i <= n and vim.uv.hrtime() > stop then
          return vim.defer_fn(work, 0) -- a timer, so input and redraws get in
        end
      end
      done()
    end)
    if not ok then
      fail(err)
    end
  end
  work()
end

--- After the buffer changed: row offset, header floats, window bars, and
--- whatever should load next.
---@param buf integer
---@param view replstudio.ParquetView
local function refresh(buf, view)
  api.nvim_buf_set_var(buf, "replstudio_r0", view.r1 - 1)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    sync_float(view, win)
    vim.wo[win][0].winbar = winbar(view, win)
  end
  M._more(buf)
end

---@class replstudio.FetchSteps
---@field first? fun(rows: string[][]): boolean? once all rows are parsed; false aborts
---@field each? fun(i: integer, row: string[]) prepare row i, a slice at a time
---@field apply fun(rows: string[][]) commit to the buffer, in one go

--- Fetch rows `a..a+n-1` of columns `j1..j2` in the background, then run
--- `steps`. Parsing and preparing are sliced; only `apply` touches the buffer.
--- Only the latest fetch gets that far.
---@param buf integer
---@param view replstudio.ParquetView
---@param a integer
---@param n integer
---@param j1 integer
---@param j2 integer
---@param steps replstudio.FetchSteps
local function fetch(buf, view, a, n, j1, j2, steps)
  local token = {}
  view.token, view.loading = token, true
  local names = {}
  for j = j1, j2 do
    names[#names + 1] = view.cols[j].name
  end
  local function live()
    return views[buf] == view and view.token == token and api.nvim_buf_is_valid(buf)
  end
  local function finish(rows)
    view.loading, view.stalled = false, false
    steps.apply(rows)
    refresh(buf, view)
  end
  local function fail(err)
    -- Keep what is shown; stop loading until the next jump or :e!.
    view.loading, view.stalled = false, true
    if err then
      vim.notify("replstudio: could not read more rows\n" .. vim.trim(err), vim.log.levels.WARN)
    end
  end
  vim.system(duckdb(M._tile_sql(view.path, names, n, a - 1)), { text = true }, function(r)
    vim.schedule(function()
      if not live() then
        return
      end
      local records = r.code == 0 and split_records(r.stdout or "") or {}
      if #records == 0 then
        -- duckdb failed, or the file changed under us.
        return fail(r.code ~= 0 and (r.stderr or "") or nil)
      end
      local rows = {}
      sliced(#records, function(i)
        rows[i] = split(records[i], "\31")
      end, live, function()
        if steps.first and steps.first(rows) == false then
          return fail()
        end
        if not steps.each then
          return finish(rows)
        end
        sliced(#rows, function(i)
          steps.each(i, rows[i])
        end, live, function()
          finish(rows)
        end, fail)
      end, fail)
    end)
  end)
end

--- How far past what `s` shows to keep loaded: rows, and display columns.
--- Moving closer than this to an edge fetches more; dropping never cuts
--- into it, so a fetch on one side cannot set off one on the other.
---@param view replstudio.ParquetView
---@param s { h: integer, w: integer }
---@return integer rows, integer cols
local function reach(view, s)
  return math.ceil(view.chunk * PREFETCH) + s.h, (PREFETCH + 1) * s.w
end

--- Rows below the loaded ones.
local function load_down(buf, view)
  local a, lines = view.r2 + 1, {}
  local function each(i, row)
    store(view, a + i - 1, view.c1, row)
    lines[i] = row_line(view, a + i - 1)
  end
  fetch(buf, view, a, math.min(view.chunk, view.total - view.r2), view.c1, view.c2, { each = each, apply = function(rows)
    view.r2 = a + #rows - 1
    -- Drop rows above every window, beyond reach.
    local s = seen(view, buf)
    local excess = view.r2 - view.r1 + 1 - SPAN * view.chunk
    local drop = math.max(0, math.min(excess, s and (s.top - reach(view, s) - view.r1) or excess))
    keep_view(buf, -drop, 0, function()
      modify(buf, function()
        api.nvim_buf_set_lines(buf, -1, -1, false, lines)
        if drop > 0 then
          api.nvim_buf_set_lines(buf, HEADER, HEADER + drop, false, {})
        end
      end)
    end)
    forget_rows(view, view.r1, view.r1 + drop - 1)
    view.r1 = view.r1 + drop
  end })
end

--- Rows above the loaded ones.
local function load_up(buf, view)
  local a, lines = math.max(1, view.r1 - view.chunk), {}
  local function each(i, row)
    store(view, a + i - 1, view.c1, row)
    lines[i] = row_line(view, a + i - 1)
  end
  fetch(buf, view, a, view.r1 - a, view.c1, view.c2, { each = each, apply = function(rows)
    -- Drop rows below every window, beyond reach.
    local s = seen(view, buf)
    view.r1 = a
    local excess = view.r2 - view.r1 + 1 - SPAN * view.chunk
    local drop = math.max(0, math.min(excess, s and (view.r2 - s.bot - reach(view, s)) or excess))
    keep_view(buf, #rows, 0, function()
      modify(buf, function()
        api.nvim_buf_set_lines(buf, HEADER, HEADER, false, lines)
        if drop > 0 then
          local n = api.nvim_buf_line_count(buf)
          api.nvim_buf_set_lines(buf, n - drop, n, false, {})
        end
      end)
    end)
    forget_rows(view, view.r2 - drop + 1, view.r2)
    view.r2 = view.r2 - drop
  end })
end

--- Columns `j1..j2` for every loaded row, then redraw. Once their widths
--- are known, `plan()` picks the columns to show, c1..c2, and how many display
--- columns the cells already on screen move right; the new lines are laid out
--- a slice at a time, and `after` runs once they are in.
---@param plan fun(): integer, integer, integer
---@param after? fun()
local function load_cols(buf, view, j1, j2, plan, after)
  local n = view.r2 - view.r1 + 1
  local c1, c2, shift
  local lines = {}
  local steps = {
    first = function(rows)
      if #rows ~= n then
        return false
      end
      measure(view, rows, j1, j2)
      c1, c2, shift = plan()
    end,
    each = function(i, row)
      local r = view.r1 + i - 1
      store(view, r, j1, row)
      lines[i] = row_line({ cells = view.cells, c1 = c1, c2 = c2 }, r)
    end,
    apply = function()
      for j = view.c1, view.c2 do
        if j < c1 or j > c2 then
          forget_cols(view, j, j)
        end
      end
      view.c1, view.c2 = c1, c2
      keep_view(buf, 0, shift, function()
        rebuild(buf, view, lines)
      end)
      if after then
        after()
      end
    end,
  }
  if n == 0 then
    -- No rows loaded (an empty table): only the header changes.
    steps.first({})
    steps.apply()
    return refresh(buf, view)
  end
  fetch(buf, view, view.r1, n, j1, j2, steps)
end

--- Columns right of the loaded ones.
local function load_right(buf, view)
  local j1, j2 = view.c2 + 1, math.min(#view.cols, view.c2 + COLS)
  load_cols(buf, view, j1, j2, function()
    -- Drop columns left of every window, beyond reach.
    local s = seen(view, buf)
    local c1, shift = view.c1, 0
    while j2 - c1 + 1 > BAND do
      local w = view.widths[c1] + SEP_W
      if s and shift + w > s.left - select(2, reach(view, s)) then
        break
      end
      c1, shift = c1 + 1, shift + w
    end
    return c1, j2, -shift
  end)
end

--- Columns left of the loaded ones.
local function load_left(buf, view)
  local j1, j2 = math.max(1, view.c1 - COLS), view.c1 - 1
  load_cols(buf, view, j1, j2, function()
    local shift = span_width(view, j1, j2)
    -- Drop columns right of every window, beyond reach.
    local s = seen(view, buf)
    local right = s and (s.right + shift + select(2, reach(view, s))) or 0
    local c2 = view.c2
    local width = span_width(view, j1, c2) - SEP_W + 1
    while c2 - j1 + 1 > BAND do
      local w = view.widths[c2] + SEP_W
      if s and width - w < right then
        break
      end
      c2, width = c2 - 1, width - w
    end
    return j1, c2, shift
  end)
end

--- Fetch the next chunk if a window on `buf` comes near an edge of the
--- loaded rows or columns.
---@param buf integer
function M._more(buf)
  local view = views[buf]
  if not view or not view.cols or view.loading or view.stalled then
    return
  end
  local s = seen(view, buf)
  if not s then
    return
  end
  local rows, cols = reach(view, s)
  if view.r2 < view.total and view.r2 - s.bot < rows then
    load_down(buf, view)
  elseif view.r1 > 1 and s.top - view.r1 < rows then
    load_up(buf, view)
  elseif view.c2 < #view.cols and view.bandw - s.right < cols then
    load_right(buf, view)
  elseif view.c1 > 1 and s.left < cols then
    load_left(buf, view)
  end
end

-- ── jumps ───────────────────────────────────────────────────────────────────

--- Put the cursor on data row `r`, fetching a chunk around it first if it
--- is not loaded.
---@param buf integer
---@param view replstudio.ParquetView
---@param r integer
local function goto_row(buf, view, r)
  r = math.max(1, math.min(view.total, r))
  local vcol = vim.fn.virtcol(".")
  local function land()
    api.nvim_win_set_cursor(0, { HEADER + r - view.r1 + 1, 0 })
    vim.cmd("normal! " .. vcol .. "|")
  end
  if r >= view.r1 and r <= view.r2 then
    return land()
  end
  local a = math.max(1, math.min(r - math.floor(view.chunk / 2), view.total - view.chunk + 1))
  local win = api.nvim_get_current_win()
  -- The new rows are laid out aside, then replace everything at once.
  local stage = { widths = view.widths, right = view.right, raw = {}, cells = {}, nulls = {}, c1 = view.c1, c2 = view.c2 }
  local lines = {}
  fetch(buf, view, a, view.chunk, view.c1, view.c2, {
    each = function(i, row)
      store(stage, a + i - 1, view.c1, row)
      lines[i] = row_line(stage, a + i - 1)
    end,
    apply = function(rows)
      view.raw, view.cells, view.nulls = stage.raw, stage.cells, stage.nulls
      view.r1, view.r2 = a, a + #rows - 1
      local here = api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf
      local leftcol = here and api.nvim_win_call(win, vim.fn.winsaveview).leftcol
      modify(buf, function()
        api.nvim_buf_set_lines(buf, HEADER, -1, false, lines)
      end)
      if here then
        api.nvim_win_call(win, function()
          r = math.max(view.r1, math.min(view.r2, r))
          land()
          vim.fn.winrestview({ leftcol = leftcol })
        end)
      end
    end,
  })
end

--- Show the first or last columns of the table, fetching them if needed.
---@param buf integer
---@param view replstudio.ParquetView
---@param last boolean
local function goto_edge_col(buf, view, last)
  local win = api.nvim_get_current_win()
  local function land()
    if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
      api.nvim_win_call(win, function()
        vim.cmd("normal! " .. (last and "$" or "0"))
      end)
    end
  end
  if (last and view.c2 == #view.cols) or (not last and view.c1 == 1) then
    return land()
  end
  local j1 = last and math.max(1, #view.cols - 2 * COLS + 1) or 1
  local j2 = last and #view.cols or math.min(#view.cols, 2 * COLS)
  load_cols(buf, view, j1, j2, function()
    return j1, j2, 0
  end, land)
end

-- ── navigation ──────────────────────────────────────────────────────────────

--- Loaded column index under the cursor (1-based from c1).
---@param view replstudio.ParquetView
---@return integer
local function col_at(view)
  return col_at_vcol(view, vim.fn.virtcol(".") - 1)
end

---@param view replstudio.ParquetView
---@param k integer loaded column index
local function goto_col(view, k)
  k = math.max(1, math.min(#view.starts, k))
  local s, w = view.starts[k], view.widths[view.c1 + k - 1]
  vim.cmd("normal! " .. (s + 1) .. "|")
  -- Show the whole cell when it fits.
  local info = vim.fn.getwininfo(api.nvim_get_current_win())[1]
  local text = info.width - info.textoff
  local v = vim.fn.winsaveview()
  if s + w > v.leftcol + text then
    v.leftcol = math.max(0, math.min(s - 1, s + w + 1 - text))
  elseif s - 1 < v.leftcol then
    v.leftcol = math.max(0, s - 1)
  end
  vim.fn.winrestview({ leftcol = v.leftcol })
end

---@param view replstudio.ParquetView
local function show_cell(view)
  local lnum = api.nvim_win_get_cursor(0)[1]
  local j = view.c1 + col_at(view) - 1
  local col = view.cols[j]
  local r = view.r1 + lnum - HEADER - 1
  local row = lnum > HEADER and view.raw[r]
  local v = row and row[j]
  local function show(value)
    local lines = { ("%s  ·  %s%s"):format(clean(col.name), clean(col.type), row and ("  ·  row " .. r) or "") }
    if row then
      lines[2] = ("─"):rep(math.max(20, api.nvim_strwidth(lines[1])))
      vim.list_extend(lines, value == NULL and { "NULL" } or vim.split(value, "\n", { plain = true }))
    end
    vim.lsp.util.open_floating_preview(lines, "", { border = "rounded", max_width = 100, focus_id = "replstudio_cell" })
  end
  if not (v and v ~= NULL and vim.fn.strchars(v) >= CELL_CHARS) then
    return show(v)
  end
  -- The cell was cut on reading: get the whole value.
  vim.system(duckdb(M._tile_sql(view.path, { col.name }, 1, r - 1, true)), { text = true }, function(res)
    vim.schedule(function()
      show(res.code == 0 and (res.stdout or ""):gsub("\30$", "") or v)
    end)
  end)
end

---@param buf integer
local function close(buf)
  if rawget(_G, "Snacks") and Snacks.bufdelete then
    Snacks.bufdelete(buf)
  else
    vim.cmd.bdelete(buf)
  end
end

-- ── finding columns ─────────────────────────────────────────────────────────

--- Columns whose name matches `query`: the exact name, else the name in any
--- case, else names containing it (any case); in table order.
---@param cols { name: string }[]
---@param query string
---@return integer[] column indices
function M._match_columns(cols, query)
  local exact, icase, part = {}, {}, {}
  local q = query:lower()
  for j, c in ipairs(cols) do
    local n = c.name:lower()
    if c.name == query then
      exact[#exact + 1] = j
    elseif n == q then
      icase[#icase + 1] = j
    elseif n:find(q, 1, true) then
      part[#part + 1] = j
    end
  end
  return #exact > 0 and exact or #icase > 0 and icase or part
end

--- Put the cursor on column `j` (any column of the table), fetching it first
--- if it is not loaded.
---@param buf integer
---@param view replstudio.ParquetView
---@param j integer
local function goto_column(buf, view, j)
  local win = api.nvim_get_current_win()
  local function land()
    if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
      api.nvim_win_call(win, function()
        goto_col(view, j - view.c1 + 1)
      end)
    end
  end
  if j >= view.c1 and j <= view.c2 then
    return land()
  end
  local j1 = math.max(1, math.min(j - COLS, #view.cols - 2 * COLS + 1))
  local j2 = math.min(#view.cols, j1 + 2 * COLS - 1)
  load_cols(buf, view, j1, j2, function()
    return j1, j2, 0
  end, land)
end

--- Pick a column by name with vim.ui.select (the fuzzy picker, in LazyVim).
---@param buf integer
---@param view replstudio.ParquetView
---@param choices? integer[] column indices to offer; all by default
local function pick_column(buf, view, choices)
  if not choices then
    choices = {}
    for j = 1, #view.cols do
      choices[j] = j
    end
  end
  vim.ui.select(choices, {
    prompt = "Column",
    format_item = function(j)
      return ("%s  %s  #%d"):format(view.heads[j][1], view.heads[j][3], j)
    end,
  }, function(j)
    if j and views[buf] == view then
      goto_column(buf, view, j)
    end
  end)
end

--- `:ReplStudio column [name]`: go to a column of the table in the current
--- buffer. No name, or several matches: pick one.
---@param query? string
function M.column(query)
  local buf = api.nvim_get_current_buf()
  local view = views[buf]
  if not (view and view.cols) then
    return vim.notify("Not a parquet table", vim.log.levels.WARN, { title = "replstudio" })
  end
  if not query or query == "" then
    return pick_column(buf, view)
  end
  local found = M._match_columns(view.cols, query)
  if #found == 0 then
    return vim.notify("No column matches " .. query, vim.log.levels.WARN, { title = "replstudio" })
  elseif #found == 1 then
    return goto_column(buf, view, found[1])
  end
  pick_column(buf, view, found)
end

--- Column names of the table in the current buffer, for completion.
---@return string[]
function M.column_names()
  local view = views[api.nvim_get_current_buf()]
  if not (view and view.cols) then
    return {}
  end
  return vim.tbl_map(function(c)
    return c.name
  end, view.cols)
end

---@param buf integer
local function keymaps(buf)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, function()
      local view = views[buf]
      if view and view.cols then
        fn(view)
      end
    end, { buffer = buf, desc = desc, silent = true, nowait = true })
  end
  map("w", function(v)
    goto_col(v, col_at(v) + 1)
  end, "Next column")
  map("b", function(v)
    goto_col(v, col_at(v) - 1)
  end, "Previous column")
  map("<Tab>", function(v)
    goto_col(v, col_at(v) + 1)
  end, "Next column")
  map("<S-Tab>", function(v)
    goto_col(v, col_at(v) - 1)
  end, "Previous column")
  map("K", show_cell, "Show full cell")
  map("G", function(v)
    goto_row(buf, v, vim.v.count > 0 and vim.v.count or v.total)
  end, "Last row (or row {count})")
  map("gg", function(v)
    goto_row(buf, v, math.max(vim.v.count, 1))
  end, "First row (or row {count})")
  map("$", function(v)
    goto_edge_col(buf, v, true)
  end, "Last column")
  map("0", function(v)
    goto_edge_col(buf, v, false)
  end, "First column")
  vim.keymap.set("n", "q", function()
    close(buf)
  end, { buffer = buf, desc = "Close parquet viewer", silent = true, nowait = true })

  local p = config.prefix
  if p then
    map(p .. "f", function(v)
      pick_column(buf, v)
    end, "Find column")
    local ok, wk = pcall(require, "which-key")
    if ok then
      wk.add({ { p, group = "repl studio", icon = { icon = "󰐊 ", color = "blue" }, buffer = buf } })
    end
  end
end

-- ── autocmds ────────────────────────────────────────────────────────────────

local watching = false
local function watch()
  if watching then
    return
  end
  watching = true
  api.nvim_create_autocmd({ "BufWinEnter", "WinClosed" }, {
    group = group,
    callback = vim.schedule_wrap(prune),
  })
  -- Fires on horizontal/vertical scroll, on resize and for a new split
  -- (which gets no BufWinEnter); v:event is keyed by the changed window ids.
  api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function()
      for key in pairs(vim.v.event) do
        local win = tonumber(key)
        if win and api.nvim_win_is_valid(win) then
          local buf = api.nvim_win_get_buf(win)
          local view = views[buf]
          if view and view.cols and api.nvim_win_get_config(win).relative == "" then
            sync_float(view, win)
            vim.wo[win][0].winbar = winbar(view, win)
            M._more(buf)
          end
        end
      end
    end,
  })
  -- NULLs, only on the lines being drawn.
  api.nvim_set_decoration_provider(ns_null, {
    on_win = function(_, _, buf)
      local view = views[buf]
      return view ~= nil and view.cols ~= nil
    end,
    on_line = function(_, _, buf, row)
      local view = views[buf]
      if row < HEADER then
        return
      end
      for _, s in ipairs(null_spans(view, view.r1 + row - HEADER)) do
        api.nvim_buf_set_extmark(buf, ns_null, row, s[1], {
          end_col = s[2],
          hl_group = "ReplStudioParquetNull",
          ephemeral = true,
        })
      end
    end,
  })
end

---@param buf integer
---@param lines string[]
local function fail(buf, lines)
  local view = views[buf]
  if view then
    view.cols = nil
    for win in pairs(view.floats) do
      close_float(view, win)
    end
  end
  set_lines(buf, lines)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.wo[win][0].winbar = ""
    vim.wo[win][0].statuscolumn = ""
  end
end

---@param buf integer
---@param res { total: integer, cols: table[], rows: string[][] }
local function render(buf, res)
  local view = views[buf]
  view.total, view.cols = res.total, res.cols
  view.chunk = M._chunk(#res.cols)
  view.widths, view.raw, view.cells, view.nulls = {}, {}, {}, {}
  view.r1, view.r2 = 1, #res.rows
  view.c1, view.c2 = 1, math.min(#res.cols, OPEN_COLS)
  init_heads(view)
  measure(view, res.rows, view.c1, view.c2)
  for r, row in ipairs(res.rows) do
    store(view, r, 1, row)
  end
  rebuild(buf, view)
  sep_syntax(buf)
  api.nvim_buf_set_var(buf, "replstudio_r0", 0)

  watch()
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    setup_win(buf, win)
    if api.nvim_win_get_cursor(win)[1] <= HEADER and view.r2 > 0 then
      api.nvim_win_set_cursor(win, { HEADER + 1, 0 })
    end
  end
  M._more(buf)
end

--- BufReadCmd handler: show `buf`'s parquet file as a table.
---@param buf integer
function M.open(buf)
  local path = vim.fn.fnamemodify(api.nvim_buf_get_name(buf), ":p")
  local bo = vim.bo[buf]
  bo.buftype = "nowrite"
  bo.swapfile = false
  bo.undolevels = -1

  local old = views[buf]
  local view = { path = path, floats = old and old.floats or {}, hbuf = old and old.hbuf, starts = {} }
  views[buf] = view
  -- Set up afresh on every open: :bdelete clears buffer-local maps.
  keymaps(buf)
  api.nvim_clear_autocmds({ group = group, buffer = buf })
  api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    buffer = buf,
    callback = function()
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        setup_win(buf, win)
      end
    end,
  })
  api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = buf,
    callback = function()
      local v = views[buf]
      local pos = api.nvim_win_get_cursor(0)
      if v and v.cols and v.r2 >= v.r1 and pos[1] <= HEADER then
        -- Back to the first row, same screen column: the header lines are
        -- built from 3-byte "─"/"│", so a byte offset would land elsewhere.
        local vcol = vim.fn.virtcol(".")
        api.nvim_win_set_cursor(0, { HEADER + 1, 0 })
        vim.cmd("normal! " .. vcol .. "|")
      end
      M._more(buf)
    end,
  })
  api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    buffer = buf,
    callback = function()
      local v = views[buf]
      views[buf] = nil
      if v then
        for win in pairs(v.floats) do
          close_float(v, win)
        end
        if v.hbuf and api.nvim_buf_is_valid(v.hbuf) then
          api.nvim_buf_delete(v.hbuf, { force = true })
        end
      end
    end,
  })
  bo.filetype = "parquet"

  if vim.fn.executable("duckdb") == 0 then
    return fail(buf, { "  The parquet viewer needs the duckdb CLI:", "", "    brew install duckdb" })
  end
  set_lines(buf, { "  Reading " .. vim.fn.fnamemodify(path, ":t") .. " …" })

  vim.system(duckdb(M._sql(path, config.parquet.rows)), { text = true }, function(r)
    vim.schedule(function()
      if not api.nvim_buf_is_valid(buf) or views[buf] ~= view then
        return
      end
      local res = r.code == 0 and M._parse(r.stdout or "")
      if not res then
        local msg = vim.split(vim.trim(r.stderr ~= "" and r.stderr or "duckdb returned no result"), "\n")
        return fail(buf, vim.list_extend({ "  duckdb could not read this file:", "" }, msg))
      end
      render(buf, res)
    end)
  end)
end

return M
