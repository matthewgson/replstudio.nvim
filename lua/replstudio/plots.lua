--- Plot pane: history of PNGs written by the interpreter hooks, drawn with
--- Snacks.image (kitty graphics, tmux-safe unicode placeholders).
---
--- Hooks write <page>_<rev>.png into their REPL's directory: a new page is a
--- new history entry, a new revision of the same page (e.g. `lines()` after
--- `plot()`, or `plt.title()` after `plt.plot()`) replaces that entry.
---
--- Each arriving file is moved into one history directory per Neovim
--- instance, so the history outlives REPL restarts and is deleted when Neovim
--- exits. Every file gets a fresh name because Snacks caches images by path.

local config = require("replstudio.config")
local layout = require("replstudio.layout")

local api = vim.api
local uv = vim.uv
local M = {}

---@class replstudio.Plot
---@field key string
---@field file string
---@field rev integer
---@field label string

---@type replstudio.Plot[]
local list = {}
---@type table<string, replstudio.Plot>
local by_key = {}
local idx = 0

local history_dir = ("%s/replstudio/%d-plots"):format(vim.fn.stdpath("cache"), vim.fn.getpid())
local seq = 0

local buf ---@type integer|nil
local new_buf ---@type fun(): integer
local placement ---@type snacks.image.Placement|nil
local detected = false

local function snacks()
  return rawget(_G, "Snacks") ~= nil and Snacks.image ~= nil
end

--- One reusable single-shot timer per name.
local timers = {}
local function debounce(name, ms, fn)
  local t = timers[name]
  if not t then
    t = assert(uv.new_timer())
    timers[name] = t
  end
  t:stop()
  t:start(ms, 0, vim.schedule_wrap(fn))
end

function M.has_plots()
  return #list > 0
end

-- ── size handshake ──────────────────────────────────────────────────────────

--- Cells of the plot pane, or of where it would open.
---@return integer cols, integer rows
local function pane_cells()
  local win = layout.plots_win()
  if win then
    local info = vim.fn.getwininfo(win)[1]
    return info.width, info.height
  end
  local mode = layout.mode()
  if mode == "focus" then
    local f = layout.float_config()
    return f.width, f.height
  end
  local cols = math.max(20, math.floor(vim.o.columns * config.size.plots))
  local rows = vim.o.lines - vim.o.cmdheight - 2
  return cols, mode == "side" and math.floor(rows / 2) or rows
end

local resize_au = false

--- Write "<width_px> <height_px> <dpi>" for every session's hooks.
function M.write_size()
  if not resize_au then
    resize_au = true
    api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
      group = api.nvim_create_augroup("replstudio.plots", { clear = true }),
      callback = function()
        debounce("size", 80, M.write_size)
      end,
    })
  end
  local cols, rows = pane_cells()
  local cw, ch = 9, 18
  if snacks() then
    local t = Snacks.image.terminal.size()
    cw, ch = t.cell_width, t.cell_height
  end
  local dpi = math.floor(72 * (cw / 8) * config.plot_scale + 0.5)
  local line = ("%d %d %d\n"):format(math.floor(cols * cw), math.floor(rows * ch), dpi)
  for _, s in pairs(require("replstudio.repl").sessions) do
    local tmp = s.dir .. "/size.tmp"
    local fd = io.open(tmp, "w")
    if fd then
      fd:write(line)
      fd:close()
      uv.fs_rename(tmp, s.dir .. "/size")
    end
  end
end

-- ── rendering ───────────────────────────────────────────────────────────────

local function winbar()
  local win = layout.plots_win()
  if not win then
    return
  end
  local p = list[idx]
  vim.wo[win].winbar = p and ("%%#Title# plot %d/%d %%* %s"):format(idx, #list, p.label) or "%#Title# plots %*"
end

local function set_lines(lines)
  local b = M.buf()
  vim.bo[b].modifiable = true
  api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false
end

function M.render()
  winbar()
  local p = list[idx]
  if not p or not layout.plots_win() then
    return
  end
  if not snacks() then
    set_lines({ "", "  snacks.nvim is needed to draw plots.", "  o: open " .. vim.fn.fnamemodify(p.file, ":t") })
    return
  end
  if not detected then
    Snacks.image.terminal.detect(function()
      detected = true
      M.render()
    end)
    return
  end
  if not Snacks.image.supports_terminal() then
    set_lines({ "", "  This terminal has no kitty graphics support.", "  o: open the plot externally" })
    return
  end
  -- A fresh buffer per plot. Snacks' loading spinner outlives a placement
  -- closed mid-load and keeps clearing its buffer's extmarks; it only stops
  -- once that buffer is gone. Swapping buffers (the old one is wiped) means
  -- fast browsing can never leave the pane blank.
  if placement then
    placement:close()
    placement = nil
  end
  local win = assert(layout.plots_win())
  local fresh = new_buf()
  api.nvim_win_set_buf(win, fresh) -- the previous buffer wipes itself
  buf = fresh
  layout.style(win)
  winbar()
  placement = Snacks.image.placement.new(fresh, p.file, {
    pos = { 1, 0 },
    inline = false,
    conceal = true,
    auto_resize = true,
  })
end

--- Re-draw into a (possibly new) plot window.
function M.refresh()
  if placement then
    placement:close()
    placement = nil
  end
  M.render()
end

--- Called from the session watcher for every finished PNG.
---@param s replstudio.Session
---@param path string
function M.on_file(s, path)
  local page, rev = vim.fs.basename(path):match("^(%d+)_(%d+)%.png$")
  rev = tonumber(rev)
  local key = s.id .. ":" .. page
  local p = by_key[key]
  -- Deleting a superseded revision also fires an event (macOS reports it as
  -- a rename): only ever move forward, and only to files that exist.
  if (p and rev <= p.rev) or not uv.fs_stat(path) then
    return
  end
  if seq == 0 then
    vim.fn.mkdir(history_dir, "p")
  end
  seq = seq + 1
  local dest = ("%s/%05d.png"):format(history_dir, seq)
  if not uv.fs_rename(path, dest) then
    return
  end
  if p then
    vim.fn.delete(p.file)
    p.file, p.rev = dest, rev
  else
    p = { key = key, file = dest, rev = rev, label = s.spec.label:match("^(%S+)") or s.lang }
    list[#list + 1] = p
    by_key[key] = p
  end
  for i, item in ipairs(list) do
    if item == p then
      idx = i
      break
    end
  end
  -- A loop drawing many plots renders only the last of a burst.
  debounce("render", 30, function()
    if config.auto_open_plots and not layout.plots_win() then
      layout.show_plots(M.buf())
    end
    M.render()
  end)
end

--- Delete the history (VimLeavePre).
function M.cleanup()
  vim.fn.delete(history_dir, "rf")
end

-- ── navigation & actions ────────────────────────────────────────────────────

local function go(delta)
  if #list == 0 then
    return
  end
  idx = math.max(1, math.min(#list, idx + delta))
  if not layout.plots_win() then
    layout.show_plots(M.buf())
  end
  M.render()
end

function M.prev()
  go(-1)
end

function M.next()
  go(1)
end

function M.toggle()
  if layout.plots_win() then
    layout.hide_plots()
  else
    layout.show_plots(M.buf())
    M.refresh()
    M.write_size()
  end
end

function M.open_external()
  local p = list[idx]
  if p then
    vim.ui.open(p.file)
  end
end

function M.yank_path()
  local p = list[idx]
  if p then
    vim.fn.setreg("+", p.file)
    vim.notify("copied " .. p.file, vim.log.levels.INFO, { title = "replstudio" })
  end
end

function M.save_as()
  local p = list[idx]
  if not p then
    return
  end
  vim.ui.input({ prompt = "Save plot as: ", default = uv.cwd() .. "/plot.png", completion = "file" }, function(dest)
    if not dest or dest == "" then
      return
    end
    dest = vim.fs.normalize(dest)
    local ok, err = uv.fs_copyfile(p.file, dest)
    vim.notify(ok and ("saved " .. dest) or ("save failed: " .. tostring(err)), ok and vim.log.levels.INFO or vim.log.levels.ERROR, { title = "replstudio" })
  end)
end

function M.delete()
  local p = table.remove(list, idx)
  if not p then
    return
  end
  by_key[p.key] = nil
  vim.fn.delete(p.file)
  idx = math.min(idx, #list)
  if placement and #list == 0 then
    placement:close()
    placement = nil
  end
  M.render()
end

function M.zoom()
  local p = list[idx]
  if not p or not snacks() then
    return
  end
  local zbuf = api.nvim_create_buf(false, true)
  local width, height = math.floor(vim.o.columns * 0.9), math.floor(vim.o.lines * 0.85)
  local win = api.nvim_open_win(zbuf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    border = "rounded",
    title = (" plot %d/%d "):format(idx, #list),
    title_pos = "center",
    zindex = 60,
  })
  local zp = Snacks.image.placement.new(zbuf, p.file, { pos = { 1, 0 }, inline = false, conceal = true, auto_resize = true })
  local function close()
    zp:close()
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
    if api.nvim_buf_is_valid(zbuf) then
      api.nvim_buf_delete(zbuf, { force = true })
    end
  end
  for _, key in ipairs({ "q", "<Esc>", "z" }) do
    vim.keymap.set("n", key, close, { buffer = zbuf, nowait = true, desc = "Close zoom" })
  end
  api.nvim_create_autocmd("WinLeave", { buffer = zbuf, once = true, callback = close })
end

-- ── buffer ──────────────────────────────────────────────────────────────────

---@return integer
function new_buf()
  local b = api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = "wipe"
  vim.bo[b].filetype = "replstudioview"
  vim.bo[b].modifiable = false
  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = b, nowait = true, desc = desc })
  end
  map("h", M.prev, "Previous plot")
  map("l", M.next, "Next plot")
  map("o", M.open_external, "Open plot externally")
  map("y", M.yank_path, "Copy plot path")
  map("s", M.save_as, "Save plot as")
  map("d", M.delete, "Delete plot")
  map("z", M.zoom, "Zoom plot")
  map("q", layout.hide_plots, "Hide plots")
  return b
end

--- The plot pane's current buffer (a new one when none is alive).
---@return integer
function M.buf()
  if not (buf and api.nvim_buf_is_valid(buf)) then
    buf = new_buf()
  end
  return buf
end

return M
