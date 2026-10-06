--- Read-only parquet viewer: opening a *.parquet file shows its first rows
--- as an aligned table instead of binary.
---
--- One `duckdb` call per open: row count and schema come from the file
--- footer, and `LIMIT n` reads only the first row group(s), so a file of any
--- size opens in a few tens of milliseconds. Nothing runs after that.
---
--- Buffer layout: three header lines (names, types, rule), then one line per
--- row. A non-focusable float pinned over the window's top lines repeats the
--- header, following horizontal scroll, so names and types stay visible.
--- Row numbers live in 'statuscolumn', which does not scroll sideways.

local config = require("replstudio.config")

local api = vim.api
local M = {}

local HEADER = 3
local SEP = " │ " -- 5 bytes, 3 columns
local SEP_W = 3
local NULL = "\1"
local ns = api.nvim_create_namespace("replstudio.parquet")
local group = api.nvim_create_augroup("replstudio.parquet", { clear = true })

---@class replstudio.ParquetView
---@field path string
---@field cols { name: string, type: string, kind: string }[]
---@field rows string[][] raw values, NULL for SQL NULL
---@field widths integer[]
---@field starts integer[] 0-based display column where each cell starts
---@field total integer
---@field header string[]
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
      local n = vim.fn.strchars(s)
      repeat
        n = n - 1
        s = vim.fn.strcharpart(s, 0, n)
      until api.nvim_strwidth(s) <= width - 1
    end
    s = s .. "…"
    w = api.nvim_strwidth(s)
  end
  local pad = (" "):rep(width - w)
  return right and pad .. s or s .. pad
end

-- ── table layout ────────────────────────────────────────────────────────────

--- Build the buffer lines and highlight spans for a parsed result.
---@param view replstudio.ParquetView
---@return string[] lines
---@return { [1]: integer, [2]: integer, [3]: integer, [4]: string }[] marks (row, byte start, byte end, group)
function M._layout(view)
  local max = config.parquet.max_width
  local cols, rows = view.cols, view.rows
  local widths, cells = {}, {}
  for j, c in ipairs(cols) do
    widths[j] = math.min(max, math.max(api.nvim_strwidth(c.name), #c.type, 4))
  end
  for i, row in ipairs(rows) do
    local line = {}
    for j = 1, #cols do
      local v = row[j]
      local s, w
      if v == NULL then
        s, w = "NULL", 4
      else
        s, w = clean(v)
      end
      line[j] = { s, w }
      if w > widths[j] then
        widths[j] = math.min(max, w)
      end
    end
    cells[i] = line
  end

  local starts, at = {}, 1
  for j, w in ipairs(widths) do
    starts[j] = at
    at = at + w + SEP_W
  end
  view.widths, view.starts = widths, starts

  local marks = {}
  local names, types, rule = {}, {}, {}
  local nb, tb = 1, 1 -- byte offsets (leading space)
  for j, c in ipairs(cols) do
    local name = fit(c.name, api.nvim_strwidth(c.name), widths[j], false)
    local type = fit(c.type, #c.type, widths[j], false)
    marks[#marks + 1] = { 0, nb, nb + #name, "ReplStudioParquetName" }
    marks[#marks + 1] = { 1, tb, tb + #type, kind_hl[c.kind] }
    names[j], types[j], rule[j] = name, type, ("─"):rep(widths[j])
    nb, tb = nb + #name + #SEP, tb + #type + #SEP
  end
  local lines = {
    " " .. table.concat(names, SEP),
    " " .. table.concat(types, SEP),
    "─" .. table.concat(rule, "─┼─"),
  }
  for i, line in ipairs(cells) do
    local parts, b = {}, 1
    for j, cell in ipairs(line) do
      local right = cols[j].kind == "num"
      local s = fit(cell[1], cell[2], widths[j], right)
      if rows[i][j] == NULL then
        local off = right and #s - 4 or 0
        marks[#marks + 1] = { HEADER + i - 1, b + off, b + off + 4, "ReplStudioParquetNull" }
      end
      parts[j] = s
      b = b + #s + #SEP
    end
    lines[#lines + 1] = " " .. table.concat(parts, SEP)
  end
  return lines, marks
end

-- ── duckdb ──────────────────────────────────────────────────────────────────

---@param path string
---@param limit integer
---@return string
function M._sql(path, limit)
  local f = "'" .. path:gsub("'", "''") .. "'"
  return table.concat({
    ("SELECT count(*), (SELECT count(*) FROM (DESCRIBE SELECT * FROM %s)) FROM %s;"):format(f, f),
    ("DESCRIBE SELECT * FROM %s;"):format(f),
    ("SELECT COLUMNS(*)::VARCHAR FROM %s LIMIT %d;"):format(f, limit),
  }, "\n")
end

--- Parse `duckdb -list` output (fields \31, records \30, NULL \1).
---@param out string
---@return { total: integer, cols: table[], rows: string[][] }|nil
function M._parse(out)
  local records = vim.split(out, "\30", { plain = true })
  if records[#records] == "" then
    records[#records] = nil
  end
  local head = vim.split(records[1] or "", "\31", { plain = true })
  local total, ncol = tonumber(head[1]), tonumber(head[2])
  if not total or not ncol then
    return nil
  end
  local cols = {}
  for i = 2, ncol + 1 do
    local f = vim.split(records[i], "\31", { plain = true })
    cols[#cols + 1] = { name = f[1], type = f[2]:lower(), kind = M._kind(f[2]) }
  end
  local rows = {}
  for i = ncol + 2, #records do
    rows[#rows + 1] = vim.split(records[i], "\31", { plain = true })
  end
  return { total = total, cols = cols, rows = rows }
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
          local view = views[api.nvim_win_get_buf(win)]
          if view and view.cols and api.nvim_win_get_config(win).relative == "" then
            sync_float(view, win)
          end
        end
      end
    end,
  })
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

---@param view replstudio.ParquetView
---@return string
local function winbar(view)
  local name = vim.fn.fnamemodify(view.path, ":t"):gsub("%%", "%%%%")
  local shown = #view.rows
  local size = shown < view.total and ("first %s of %s rows"):format(commas(shown), commas(view.total))
    or ("%s rows"):format(commas(view.total))
  return ("%%#ReplStudioParquetName# 󰓫 %s %%#Comment# %s × %d cols%%=%%<K cell · w/b column · q close "):format(
    name,
    size,
    #view.cols
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
  wo.numberwidth = #tostring(view and #view.rows or 0) + 2
  wo.statuscolumn = "%=%{v:lnum>" .. HEADER .. "?v:lnum-" .. HEADER .. ":''} "
  wo.scrolloff = math.max(vim.o.scrolloff, HEADER)
  wo.sidescrolloff = 0
  wo.winbar = view and view.cols and winbar(view) or ""
  if view and view.cols then
    sync_float(view, win)
  end
end

-- ── navigation ──────────────────────────────────────────────────────────────

--- Column index under the cursor (1-based), from its display column.
---@param view replstudio.ParquetView
---@return integer
local function col_at(view)
  local vc = vim.fn.virtcol(".") - 1
  local j = 1
  for k, s in ipairs(view.starts) do
    if s <= vc then
      j = k
    end
  end
  return j
end

---@param view replstudio.ParquetView
---@param j integer
local function goto_col(view, j)
  j = math.max(1, math.min(#view.starts, j))
  local s, w = view.starts[j], view.widths[j]
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
  local j = col_at(view)
  local col = view.cols[j]
  local row = view.rows[lnum - HEADER]
  local v = row and row[j]
  local lines = { ("%s  ·  %s%s"):format(col.name, col.type, row and ("  ·  row " .. (lnum - HEADER)) or "") }
  if row then
    lines[2] = ("─"):rep(math.max(20, api.nvim_strwidth(lines[1])))
    vim.list_extend(lines, v == NULL and { "NULL" } or vim.split(v, "\n", { plain = true }))
  end
  vim.lsp.util.open_floating_preview(lines, "", { border = "rounded", max_width = 100, focus_id = "replstudio_cell" })
end

---@param buf integer
local function close(buf)
  if rawget(_G, "Snacks") and Snacks.bufdelete then
    Snacks.bufdelete(buf)
  else
    vim.cmd.bdelete(buf)
  end
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
  vim.keymap.set("n", "q", function()
    close(buf)
  end, { buffer = buf, desc = "Close parquet viewer", silent = true, nowait = true })
end

-- ── buffer ──────────────────────────────────────────────────────────────────

---@param buf integer
---@param lines string[]
local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
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
  view.total, view.cols, view.rows = res.total, res.cols, res.rows
  local lines, marks = M._layout(view)
  set_lines(buf, lines)
  sep_syntax(buf)
  apply_marks(buf, marks)

  -- Header buffer for the floats: the first three lines, same highlights.
  if not (view.hbuf and api.nvim_buf_is_valid(view.hbuf)) then
    view.hbuf = api.nvim_create_buf(false, true)
    vim.bo[view.hbuf].bufhidden = "hide"
    sep_syntax(view.hbuf)
  end
  local hb = view.hbuf
  vim.bo[hb].modifiable = true
  api.nvim_buf_set_lines(hb, 0, -1, false, vim.list_slice(lines, 1, HEADER))
  vim.bo[hb].modifiable = false
  apply_marks(
    hb,
    vim.tbl_filter(function(m)
      return m[1] < HEADER
    end, marks)
  )

  watch()
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    setup_win(buf, win)
    if api.nvim_win_get_cursor(win)[1] <= HEADER and #lines > HEADER then
      api.nvim_win_set_cursor(win, { HEADER + 1, 0 })
    end
  end
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
  views[buf] = { path = path, floats = old and old.floats or {}, hbuf = old and old.hbuf, cols = nil, rows = {} }
  if not old then
    keymaps(buf)
    api.nvim_create_autocmd("BufWinEnter", {
      group = group,
      buffer = buf,
      callback = function()
        setup_win(buf, api.nvim_get_current_win())
      end,
    })
    api.nvim_create_autocmd("CursorMoved", {
      group = group,
      buffer = buf,
      callback = function()
        local view = views[buf]
        local pos = api.nvim_win_get_cursor(0)
        if view and view.cols and #view.rows > 0 and pos[1] <= HEADER then
          api.nvim_win_set_cursor(0, { HEADER + 1, pos[2] })
        end
      end,
    })
    api.nvim_create_autocmd("BufWipeout", {
      group = group,
      buffer = buf,
      callback = function()
        local view = views[buf]
        views[buf] = nil
        if view then
          for win in pairs(view.floats) do
            close_float(view, win)
          end
          if view.hbuf and api.nvim_buf_is_valid(view.hbuf) then
            api.nvim_buf_delete(view.hbuf, { force = true })
          end
        end
      end,
    })
  end
  bo.filetype = "parquet"

  if vim.fn.executable("duckdb") == 0 then
    return fail(buf, { "  The parquet viewer needs the duckdb CLI:", "", "    brew install duckdb" })
  end
  set_lines(buf, { "  Reading " .. vim.fn.fnamemodify(path, ":t") .. " …" })

  local cmd = {
    "duckdb",
    "-init",
    "/dev/null",
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
    M._sql(path, config.parquet.rows),
  }
  vim.system(cmd, { text = true }, function(r)
    vim.schedule(function()
      if not api.nvim_buf_is_valid(buf) or not views[buf] or views[buf].path ~= path then
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
