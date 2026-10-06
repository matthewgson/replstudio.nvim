--- replstudio.nvim: R/Python REPL with a live plot pane.
---
--- Public entry point. Kept tiny: modules that do real work are required on
--- first use, so attaching keymaps costs nothing.

local config = require("replstudio.config")

local api = vim.api
local M = {}

local filetypes = { r = true, python = true, quarto = true }

---@param opts? table
function M.setup(opts)
  config.setup(opts)
end

-- ── session lookup ──────────────────────────────────────────────────────────

--- Run `fn(session)` for the cursor's language, starting the REPL if needed.
---@param lang "r"|"python"
---@param fn fun(s: replstudio.Session)
local function with_session(lang, fn)
  local detect = require("replstudio.detect")
  local buf = api.nvim_get_current_buf()
  local root = detect.root(buf)
  require("replstudio.repl").ensure(lang, root, detect.workdir(buf, root), fn)
end

--- Running session for the current buffer, else the last one used.
---@return replstudio.Session|nil
local function current()
  local repl = require("replstudio.repl")
  local buf = api.nvim_get_current_buf()
  local lang = require("replstudio.send").lang_at(buf, api.nvim_win_get_cursor(0)[1] - 1)
  if lang then
    local detect = require("replstudio.detect")
    local root = detect.root(buf)
    local s = repl.sessions[repl.key(lang, root, detect.workdir(buf, root))]
    if s then
      return s
    end
  end
  for _, s in pairs(repl.sessions) do
    if s.buf == buf then
      return s
    end
  end
  return repl.last
end

local function no_session()
  vim.notify("No REPL running", vim.log.levels.WARN, { title = "replstudio" })
end

---@param row integer|nil 0-based
local function move_to(row)
  if not row then
    return
  end
  local last = api.nvim_buf_line_count(0)
  api.nvim_win_set_cursor(0, { math.min(row + 1, last), 0 })
end

-- ── actions ─────────────────────────────────────────────────────────────────

---@param pick replstudio.Pick|nil
local function dispatch(pick)
  if not pick then
    return false
  end
  local send = require("replstudio.send")
  local parts = { pick.text }
  if pick.cell and pick.lang == "python" then
    parts = send.split("python", pick.text)
  end
  move_to(pick.next_row)
  with_session(pick.lang, function(s)
    for _, part in ipairs(parts) do
      require("replstudio.repl").send(s, send.normalize(part))
    end
  end)
  return true
end

--- <CR>: send the statement under the cursor and move past it.
function M.send_statement()
  local buf = api.nvim_get_current_buf()
  local pick = require("replstudio.send").pick_statement(buf, api.nvim_win_get_cursor(0)[1] - 1)
  if not dispatch(pick) and vim.bo[buf].filetype == "quarto" then
    -- Prose in a Quarto document: plain <CR>.
    api.nvim_feedkeys(vim.keycode("<CR>"), "n", false)
  end
end

--- Visual <CR>: send the selection.
function M.send_selection()
  local mode = vim.fn.mode()
  local from, to = vim.fn.getpos("v"), vim.fn.getpos(".")
  local lines = vim.fn.getregion(from, to, { type = mode })
  api.nvim_feedkeys(vim.keycode("<Esc>"), "n", false)
  local lang = require("replstudio.send").lang_at(0, math.min(from[2], to[2]) - 1)
  if not lang then
    return
  end
  local text = require("replstudio.send").normalize(table.concat(lines, "\n"))
  with_session(lang, function(s)
    require("replstudio.repl").send(s, text)
  end)
end

--- Send the `# %%` cell / Quarto chunk and jump to the next one.
function M.send_cell()
  dispatch(require("replstudio.send").pick_cell(0, api.nvim_win_get_cursor(0)[1] - 1))
end

--- Source the whole file (the saved file, or a snapshot when modified).
function M.source_file()
  local buf = api.nvim_get_current_buf()
  local lang = require("replstudio.send").lang_at(buf, 0) or ({ r = "r", python = "python" })[vim.bo[buf].filetype]
  if not lang or vim.bo[buf].filetype == "quarto" then
    return vim.notify("Source works in .R and .py files", vim.log.levels.WARN, { title = "replstudio" })
  end
  with_session(lang, function(s)
    local path = api.nvim_buf_get_name(buf)
    if vim.bo[buf].modified or path == "" then
      path = s.dir .. (lang == "r" and "/source.R" or "/source.py")
      vim.fn.writefile(api.nvim_buf_get_lines(buf, 0, -1, false), path)
    end
    local cmd
    if lang == "r" then
      cmd = ("source(%q, echo = TRUE, max.deparse.length = Inf)"):format(path)
    elseif s.spec.kind == "ipython" then
      cmd = ("%%run -i %q"):format(path)
    else
      cmd = ("exec(compile(open(%q).read(), %q, 'exec'))"):format(path, path)
    end
    require("replstudio.repl").send(s, cmd)
  end)
end

function M.toggle_repl()
  local layout = require("replstudio.layout")
  if layout.wins.repl and api.nvim_win_is_valid(layout.wins.repl) then
    return layout.hide_repl()
  end
  local s = current()
  if s then
    return layout.show_repl(s)
  end
  local lang = require("replstudio.send").lang_at(0, api.nvim_win_get_cursor(0)[1] - 1)
  if not lang then
    return vim.notify("Open an R or Python file to start a REPL", vim.log.levels.WARN, { title = "replstudio" })
  end
  with_session(lang, function() end)
end

function M.browse_repl()
  local s = current()
  if not s then
    return no_session()
  end
  require("replstudio.layout").browse_repl(s)
end

function M.toggle_plots()
  require("replstudio.plots").toggle()
end

function M.cycle_layout()
  require("replstudio.layout").set()
end

function M.interrupt()
  local s = current()
  if not s then
    return no_session()
  end
  require("replstudio.repl").interrupt(s)
end

function M.clear()
  local s = current()
  if not s then
    return no_session()
  end
  require("replstudio.repl").clear(s)
end

function M.quit()
  local s = current()
  if not s then
    return no_session()
  end
  require("replstudio.repl").stop(s)
end

function M.restart()
  local s = current()
  if not s then
    return no_session()
  end
  local lang, root, wd = s.lang, s.root, s.wd
  require("replstudio.repl").stop(s)
  require("replstudio.repl").ensure(lang, root, wd, function() end)
end

function M.info()
  local s = current()
  local lines = {}
  if s then
    lines[#lines + 1] = ("%s\n  cmd:  %s\n  root: %s\n  wd:   %s"):format(
      s.label,
      table.concat(s.spec.cmd, " "),
      s.root,
      s.wd
    )
  else
    lines[#lines + 1] = "No REPL running for this buffer."
  end
  local venv = require("replstudio.venv")
  lines[#lines + 1] = ("managed venv: %s%s"):format(
    vim.fn.fnamemodify(venv.path(), ":~"),
    venv.exists() and "" or " (not created)"
  )
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "replstudio" })
end

-- ── keymaps ─────────────────────────────────────────────────────────────────

--- Buffer-local mappings for an R / Python / Quarto buffer.
---@param buf integer
function M.attach(buf)
  if not filetypes[vim.bo[buf].filetype] or vim.bo[buf].buftype ~= "" or vim.b[buf].replstudio then
    return
  end
  vim.b[buf].replstudio = true
  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = desc, silent = true })
  end
  map("n", "<CR>", M.send_statement, "Send statement to REPL")
  map("x", "<CR>", M.send_selection, "Send selection to REPL")
  map("n", "<S-CR>", M.send_cell, "Send cell to REPL")
  map("n", "[p", function()
    require("replstudio.plots").prev()
  end, "Prev plot")
  map("n", "]p", function()
    require("replstudio.plots").next()
  end, "Next plot")

  local p = config.prefix
  if not p then
    return
  end
  map("n", p .. "r", M.toggle_repl, "Toggle REPL")
  map("n", p .. "o", M.browse_repl, "Browse REPL output")
  map("n", p .. "p", M.toggle_plots, "Toggle plots")
  map("n", p .. "l", M.cycle_layout, "Cycle layout")
  map("n", p .. "s", M.source_file, "Source file")
  map("n", p .. "c", M.send_cell, "Send cell")
  map("n", p .. "i", M.interrupt, "Interrupt")
  map("n", p .. "x", M.clear, "Clear console")
  map("n", p .. "R", M.restart, "Restart REPL")
  map("n", p .. "q", M.quit, "Quit REPL")
  map("n", p .. "z", function()
    require("replstudio.plots").zoom()
  end, "Zoom plot")
  map("n", p .. "v", M.info, "Interpreter info")

  local ok, wk = pcall(require, "which-key")
  if ok then
    wk.add({ { p, group = "repl studio", icon = { icon = "󰐊 ", color = "blue" }, buffer = buf } })
  end
end

-- ── :ReplStudio ─────────────────────────────────────────────────────────────

local subcommands = {
  start = function()
    M.toggle_repl()
  end,
  stop = M.quit,
  restart = M.restart,
  info = M.info,
  plots = M.toggle_plots,
  layout = function(args)
    require("replstudio.layout").set(args[1])
  end,
  venv = function(args)
    local venv = require("replstudio.venv")
    local sub = table.remove(args, 1)
    if not sub then
      M.info()
    elseif sub == "install" then
      venv.create()
    elseif sub == "rebuild" then
      venv.create(nil, true)
    elseif sub == "add" then
      venv.add(args)
    elseif sub == "update" then
      venv.update()
    else
      vim.notify("venv: install | add <pkg…> | update | rebuild", vim.log.levels.WARN, { title = "replstudio" })
    end
  end,
}

---@param line string
function M.command(line)
  local args = vim.split(vim.trim(line), "%s+", { trimempty = true })
  local name = table.remove(args, 1) or "start"
  local fn = subcommands[name]
  if not fn then
    return vim.notify("Unknown subcommand: " .. name, vim.log.levels.ERROR, { title = "replstudio" })
  end
  fn(args)
end

---@param arglead string
---@param line string
---@return string[]
function M.complete(arglead, line)
  local words = vim.split(line, "%s+", { trimempty = true })
  local n = #words + (line:match("%s$") and 1 or 0)
  local items = {}
  if n <= 2 then
    items = vim.tbl_keys(subcommands)
  elseif words[2] == "layout" and n == 3 then
    items = { "studio", "side", "focus" }
  elseif words[2] == "venv" and n == 3 then
    items = { "install", "add", "update", "rebuild" }
  end
  table.sort(items)
  return vim.tbl_filter(function(i)
    return vim.startswith(i, arglead)
  end, items)
end

return M
