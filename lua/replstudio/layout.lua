--- Window placement for the REPL and plot panes.
---
---   studio  script top-left, REPL bottom-left, plots full-height right
---   side    script full-height left, plots above REPL on the right
---   focus   REPL full-width bottom, plots in a float (top-right)
---
--- Only our two windows are ever created, moved or closed.

local config = require("replstudio.config")

local api = vim.api
local M = {}

M.modes = { "studio", "side", "focus" }

---@type {repl?: integer, plots?: integer}
M.wins = {}

local function valid(win)
  return win ~= nil and api.nvim_win_is_valid(win)
end

---@return string
function M.mode()
  M.current = M.current or config.layout
  return M.current
end

local function is_ours(win)
  return win == M.wins.repl or win == M.wins.plots
end

--- A normal editing window to split from: the current one when suitable.
---@return integer
local function anchor()
  local function normal(win)
    return api.nvim_win_get_config(win).relative == ""
      and vim.bo[api.nvim_win_get_buf(win)].buftype == ""
      and not is_ours(win)
  end
  local cur = api.nvim_get_current_win()
  if normal(cur) then
    return cur
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if normal(win) then
      return win
    end
  end
  return cur
end

local function plots_width()
  return math.max(20, math.floor(vim.o.columns * config.size.plots))
end

local function repl_height()
  return math.max(5, math.floor(vim.o.lines * config.size.repl))
end

---@return vim.api.keyset.win_config
function M.float_config()
  local width = math.floor(vim.o.columns * config.float.width)
  local height = math.floor(vim.o.lines * config.float.height)
  return {
    relative = "editor",
    anchor = "NE",
    row = 1,
    col = vim.o.columns - 1,
    width = width,
    height = height,
    border = "rounded",
    zindex = 45,
    title = " plots ",
    title_pos = "center",
  }
end

local function wo(win, opts)
  for k, v in pairs(opts) do
    vim.wo[win][k] = v
  end
end

local pane_wo = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  statuscolumn = "",
  spell = false,
  list = false,
  cursorline = false,
}

--- Window options of our panes (re-applied after a plot buffer swap, which
--- resets window-local options such as the winbar).
---@param win integer
function M.style(win)
  wo(win, pane_wo)
end

---@param buf integer
---@return integer
local function open_repl(buf)
  local mode, cfg = M.mode(), nil
  if mode == "side" then
    if valid(M.wins.plots) then
      local h = api.nvim_win_get_height(M.wins.plots)
      cfg = { split = "below", win = M.wins.plots, height = math.max(5, math.floor(h * 0.5)) }
    else
      cfg = { split = "right", win = -1, width = plots_width() }
    end
  elseif mode == "focus" then
    cfg = { split = "below", win = -1, height = repl_height() }
  else
    cfg = { split = "below", win = anchor(), height = repl_height() }
  end
  local win = api.nvim_open_win(buf, false, cfg)
  wo(win, pane_wo)
  vim.wo[win].winfixheight = mode ~= "side"
  vim.wo[win].winfixwidth = mode == "side"
  M.wins.repl = win
  return win
end

---@param buf integer
---@return integer
local function open_plots(buf)
  local mode, cfg = M.mode(), nil
  if mode == "focus" then
    cfg = M.float_config()
  elseif mode == "side" and valid(M.wins.repl) then
    local h = api.nvim_win_get_height(M.wins.repl)
    cfg = { split = "above", win = M.wins.repl, height = math.max(5, math.floor(h * 0.5)) }
  else
    cfg = { split = "right", win = -1, width = plots_width() }
  end
  local win = api.nvim_open_win(buf, false, cfg)
  wo(win, pane_wo)
  vim.wo[win].winfixwidth = mode ~= "focus"
  M.wins.plots = win
  return win
end

--- Show a session's terminal in the REPL pane, creating the pane if needed.
---@param s replstudio.Session
---@return integer win
function M.show_repl(s)
  if valid(M.wins.repl) then
    if api.nvim_win_get_buf(M.wins.repl) ~= s.buf then
      api.nvim_win_set_buf(M.wins.repl, s.buf)
      M.decorate_repl(s, M.wins.repl)
    end
    return M.wins.repl
  end
  local win = open_repl(s.buf)
  M.decorate_repl(s, win)
  return win
end

---@param s replstudio.Session
---@param win integer
function M.decorate_repl(s, win)
  if not valid(win) then
    return
  end
  vim.wo[win].winbar = "%#Title# " .. s.label:gsub("%%", "%%%%") .. " %*"
  if vim.b[s.buf].replstudio_decorated then
    return
  end
  vim.b[s.buf].replstudio_decorated = true
  -- Leave terminal mode with the same <C-hjkl> as everywhere else
  -- (remap=true so vim-tmux-navigator's mappings take over).
  for _, key in ipairs({ "<C-h>", "<C-j>", "<C-k>", "<C-l>" }) do
    vim.keymap.set("t", key, "<C-\\><C-n>" .. key, { buffer = s.buf, remap = true, desc = "Leave REPL" })
  end
  -- Entering the REPL means typing into it, unless we came to browse.
  api.nvim_create_autocmd("WinEnter", {
    buffer = s.buf,
    callback = function()
      if vim.b[s.buf].replstudio_browse then
        vim.b[s.buf].replstudio_browse = false
        return
      end
      vim.cmd.startinsert()
    end,
  })
  vim.keymap.set("n", "q", function()
    vim.cmd("wincmd p")
  end, { buffer = s.buf, nowait = true, desc = "Back to script" })
end

--- Move into the REPL in normal mode at its newest output, to scroll,
--- search and yank with the usual motions. `q` goes back, `i` types.
---@param s replstudio.Session
function M.browse_repl(s)
  local win = M.show_repl(s)
  vim.b[s.buf].replstudio_browse = true
  api.nvim_set_current_win(win)
  vim.cmd.stopinsert()
  api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(s.buf), 0 })
end

--- Keep the REPL visible and scrolled to the newest output after a send.
---@param s replstudio.Session
function M.follow(s)
  local win = M.show_repl(s)
  if api.nvim_get_current_win() ~= win then
    api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(s.buf), 0 })
  end
end

---@return integer|nil
function M.plots_win()
  return valid(M.wins.plots) and M.wins.plots or nil
end

---@param buf integer
---@return integer win
function M.show_plots(buf)
  if valid(M.wins.plots) then
    if api.nvim_win_get_buf(M.wins.plots) ~= buf then
      api.nvim_win_set_buf(M.wins.plots, buf)
    end
    return M.wins.plots
  end
  return open_plots(buf)
end

function M.hide_plots()
  if valid(M.wins.plots) then
    api.nvim_win_close(M.wins.plots, true)
  end
  M.wins.plots = nil
end

function M.hide_repl()
  if valid(M.wins.repl) then
    -- Never close the last window.
    if #api.nvim_tabpage_list_wins(0) > 1 then
      api.nvim_win_close(M.wins.repl, true)
    end
  end
  M.wins.repl = nil
end

--- Switch layout, re-opening whichever panes were visible.
---@param mode? string next in the cycle when nil
function M.set(mode)
  if not mode then
    local cur = M.mode()
    for i, m in ipairs(M.modes) do
      if m == cur then
        mode = M.modes[i % #M.modes + 1]
        break
      end
    end
  end
  if not vim.tbl_contains(M.modes, mode) then
    vim.notify("replstudio: unknown layout " .. tostring(mode), vim.log.levels.ERROR)
    return
  end
  local plots = require("replstudio.plots")
  local repl_buf = valid(M.wins.repl) and api.nvim_win_get_buf(M.wins.repl) or nil
  local show_plots = valid(M.wins.plots)
  if not repl_buf and not show_plots then
    -- Nothing visible: show what exists.
    local s = require("replstudio.repl").last
    repl_buf = s and s.buf or nil
    show_plots = plots.has_plots()
  end
  M.hide_plots()
  M.hide_repl()
  M.current = mode
  -- The plot buffer wipes itself when its window closes: take a live one.
  local plots_buf = show_plots and plots.buf() or nil
  if mode == "side" then
    if plots_buf then
      open_plots(plots_buf)
    end
    if repl_buf then
      open_repl(repl_buf)
    end
  else
    if repl_buf then
      open_repl(repl_buf)
    end
    if plots_buf then
      open_plots(plots_buf)
    end
  end
  if repl_buf then
    local s = require("replstudio.repl").last
    if s and s.buf == repl_buf then
      M.decorate_repl(s, M.wins.repl)
    end
  end
  if plots_buf then
    plots.refresh()
  end
end

return M
