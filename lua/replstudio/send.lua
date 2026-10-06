--- What to send: the top-level statement under the cursor, a `# %%` cell,
--- a Quarto chunk, or a selection. Pure range logic lives here so it can be
--- tested headless; the REPL wire format lives in repl.lua.

local M = {}

local CELL = "^%s*#%s*%%%%"

---@param line string
local function blank_or_comment(line)
  return line:find("^%s*$") ~= nil or line:find("^%s*#") ~= nil
end

--- Top-level statement around `row`, from a tree root.
--- Rows are 0-based, inclusive. Returns nil when no statement starts at or
--- after `row`.
---@param root TSNode
---@param row integer
---@return integer|nil srow, integer|nil erow, integer|nil next_row
function M.statement_in_root(root, row)
  local nodes = {} ---@type {[1]:integer, [2]:integer, [3]:boolean}[]
  for child in root:iter_children() do
    if child:named() and child:type() ~= "comment" then
      local sr, _, er, ec = child:range()
      if ec == 0 and er > sr then
        er = er - 1
      end
      nodes[#nodes + 1] = { sr, er, child:type() == "ERROR" }
    end
  end
  -- First statement that ends at or after `row`: the one under the cursor,
  -- or the next one when the cursor sits on a blank/comment line.
  local first
  for i, n in ipairs(nodes) do
    if n[2] >= row then
      first = i
      break
    end
  end
  if not first then
    return nil
  end
  local srow, erow = nodes[first][1], nodes[first][2]
  if nodes[first][3] then
    -- Unparseable code can swallow the rest of the file; send one line.
    local r = math.max(row, srow)
    return r, r, r + 1
  end
  -- Statements sharing a line (`a <- 1; b <- 2`) travel together.
  local last = first
  while nodes[last + 1] and nodes[last + 1][1] <= erow do
    last = last + 1
    erow = math.max(erow, nodes[last][2])
  end
  local next_row = nodes[last + 1] and nodes[last + 1][1] or (erow + 1)
  return srow, erow, next_row
end

--- Quarto/markdown fenced chunk around `row`: ```{r} ... ```.
---@param lines string[] 1-based buffer lines
---@param row integer 0-based
---@return {lang:string, srow:integer, erow:integer}|nil chunk body rows (0-based, inclusive)
function M.chunk(lines, row)
  local open
  for r = row + 1, 1, -1 do
    local lang = lines[r]:match("^%s*```+%s*{%s*([%w_]+)")
    if lang then
      open = { lang = lang:lower(), row = r - 1 }
      break
    end
    -- A bare fence first: a closing fence (we're in prose, or on it), or a
    -- plain non-executable code block.
    if lines[r]:find("^%s*```") then
      return nil
    end
  end
  if not open then
    return nil
  end
  for r = open.row + 2, #lines do
    if lines[r]:find("^%s*```+%s*$") then
      return { lang = open.lang, srow = open.row + 1, erow = r - 2 }
    end
  end
  return { lang = open.lang, srow = open.row + 1, erow = #lines - 1 }
end

--- `# %%` cell around `row`.
---@param lines string[]
---@param row integer 0-based
---@return integer srow, integer erow, integer next_row
function M.cell(lines, row)
  local srow = 0
  for r = row + 1, 1, -1 do
    if lines[r]:find(CELL) then
      srow = r -- 0-based row after the marker
      break
    end
  end
  local erow, next_row = #lines - 1, #lines
  for r = math.max(row + 2, srow + 1), #lines do
    if lines[r]:find(CELL) then
      erow, next_row = r - 2, r
      break
    end
  end
  return srow, erow, next_row
end

---@param lang string treesitter language
---@param text string
---@return TSNode|nil
local function string_root(lang, text)
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  if not ok then
    return nil
  end
  return parser:parse()[1]:root()
end

---@param buf integer
---@param lang string
---@return TSNode|nil
local function buffer_root(buf, lang)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, lang)
  if not ok or not parser then
    return nil
  end
  -- Incremental: free when the highlighter already parsed this buffer.
  local tree = parser:parse()[1]
  return tree and tree:root()
end

---@class replstudio.Pick
---@field lang "r"|"python"
---@field text string
---@field next_row integer|nil 0-based row to move the cursor to
---@field cell? boolean a whole cell/chunk (Python sends it per statement)

local ft_lang = { r = "r", python = "python" }

--- Statement to send for the cursor position, or nil when there is nothing
--- (end of file, or prose in a Quarto document).
---@param buf integer
---@param row integer 0-based
---@return replstudio.Pick|nil
function M.pick_statement(buf, row)
  local ft = vim.bo[buf].filetype
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local lang, offset, root, last_row = ft_lang[ft], 0, nil, #lines - 1
  if ft == "quarto" then
    local chunk = M.chunk(lines, row)
    if not chunk or not ft_lang[chunk.lang] then
      return nil
    end
    lang, offset, last_row = chunk.lang, chunk.srow, chunk.erow
    if row < chunk.srow then
      row = chunk.srow
    end
    root = string_root(lang, table.concat(lines, "\n", chunk.srow + 1, chunk.erow + 1))
  elseif lang then
    root = buffer_root(buf, lang)
  end
  if not lang then
    return nil
  end
  local srow, erow, next_row
  if root then
    srow, erow, next_row = M.statement_in_root(root, row - offset)
    if srow then
      srow, erow, next_row = srow + offset, erow + offset, next_row + offset
    end
  end
  if not srow then
    -- No parser, or nothing parsed after the cursor: fall back to the line.
    if row > last_row or blank_or_comment(lines[row + 1] or "") then
      return nil
    end
    srow, erow, next_row = row, row, row + 1
  end
  if ft == "quarto" and next_row > last_row then
    next_row = M.next_chunk_row(lines, last_row + 1) or next_row
  end
  return {
    lang = lang,
    text = table.concat(lines, "\n", srow + 1, erow + 1),
    next_row = next_row,
  }
end

--- First body row of the next chunk at or after `row`.
---@param lines string[]
---@param row integer 0-based
---@return integer|nil
function M.next_chunk_row(lines, row)
  for r = row + 1, #lines do
    if lines[r]:match("^%s*```+%s*{%s*[%w_]+") then
      return r -- 0-based row after the fence
    end
  end
end

--- Cell (or Quarto chunk) under the cursor.
---@param buf integer
---@param row integer 0-based
---@return replstudio.Pick|nil
function M.pick_cell(buf, row)
  local ft = vim.bo[buf].filetype
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if ft == "quarto" then
    local chunk = M.chunk(lines, row)
    if not chunk or not ft_lang[chunk.lang] then
      return nil
    end
    return {
      lang = chunk.lang,
      text = table.concat(lines, "\n", chunk.srow + 1, chunk.erow + 1),
      next_row = M.next_chunk_row(lines, chunk.erow + 1),
      cell = true,
    }
  end
  local lang = ft_lang[ft]
  if not lang then
    return nil
  end
  local srow, erow, next_row = M.cell(lines, row)
  return { lang = lang, text = table.concat(lines, "\n", srow + 1, erow + 1), next_row = next_row, cell = true }
end

--- Top-level statements of a block of code, in order. Python only shows the
--- value of the *last* expression in a pasted block, so cells are sent one
--- statement at a time to display every plot, like R does.
---@param lang string
---@param text string
---@return string[]
function M.split(lang, text)
  local root = string_root(lang, text)
  if not root then
    return { text }
  end
  local lines = vim.split(text, "\n", { plain = true })
  local out, row = {}, 0
  while true do
    local srow, erow, next_row = M.statement_in_root(root, row)
    if not srow then
      break
    end
    out[#out + 1] = table.concat(lines, "\n", srow + 1, erow + 1)
    row = next_row
  end
  return #out > 0 and out or { text }
end

--- Language for the cursor (Quarto: the chunk's language).
---@param buf integer
---@param row integer 0-based
---@return "r"|"python"|nil
function M.lang_at(buf, row)
  local ft = vim.bo[buf].filetype
  if ft ~= "quarto" then
    return ft_lang[ft]
  end
  local chunk = M.chunk(vim.api.nvim_buf_get_lines(buf, 0, -1, false), row)
  return chunk and ft_lang[chunk.lang] or nil
end

--- Strip a common indent and trailing blank lines; pastes stay valid Python.
---@param text string
---@return string
function M.normalize(text)
  local lines = vim.split(text, "\n", { plain = true })
  while #lines > 0 and lines[#lines]:find("^%s*$") do
    lines[#lines] = nil
  end
  local indent
  for _, l in ipairs(lines) do
    if l:find("%S") then
      local w = #l:match("^%s*")
      indent = indent and math.min(indent, w) or w
    end
  end
  if indent and indent > 0 then
    for i, l in ipairs(lines) do
      lines[i] = l:sub(indent + 1)
    end
  end
  return table.concat(lines, "\n")
end

return M
