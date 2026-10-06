--- REPL sessions: one terminal job per (language, project root, working
--- directory). The process starts in the project root (so .Rprofile / renv
--- and the project venv are found) and the hook then changes into the
--- working directory, which for a .qmd is the document's folder.
---
--- Sends are queued until the interpreter shows its first prompt, so code
--- typed while IPython or R is still starting is never lost or echoed twice.
--- Each session owns a cache directory the interpreter hooks write plots into;
--- a single fs_event watcher per session turns new files into renders.

local config = require("replstudio.config")
local detect = require("replstudio.detect")

local uv = vim.uv
local M = {}

local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
M.runtime = plugin_root .. "/runtime"

local cache_root = vim.fn.stdpath("cache") .. "/replstudio"

---@class replstudio.Session
---@field id integer
---@field key string
---@field lang "r"|"python"
---@field root string
---@field wd string working directory the hook switches to
---@field label string winbar text
---@field spec replstudio.Spec
---@field dir string
---@field buf integer
---@field job integer
---@field ready boolean first prompt seen
---@field busy boolean plain python: waiting for the prompt before the next paste
---@field writing boolean a paste/Enter pair is in flight
---@field echo_wait? boolean plain python: paste sent, waiting for its echo
---@field enter? fun() plain python: send the pending Enter
---@field queue string[]
---@field watcher? uv.uv_fs_event_t
---@field alive boolean

---@type table<string, replstudio.Session>
M.sessions = {}
--- Most recently used session: target for toggles outside code buffers.
---@type replstudio.Session|nil
M.last = nil

local next_id = 0
local swept = false

local function log(msg)
  if config.debug then
    vim.notify(msg, vim.log.levels.DEBUG, { title = "replstudio" })
  end
end

--- Remove session dirs left behind by Neovim instances that are gone.
local function sweep()
  swept = true
  vim.fn.mkdir(cache_root, "p")
  for name, kind in vim.fs.dir(cache_root) do
    local pid = tonumber(name:match("^(%d+)%-"))
    if kind == "directory" and pid and pid ~= vim.fn.getpid() and not pcall(uv.kill, pid, 0) then
      vim.fn.delete(cache_root .. "/" .. name, "rf")
    end
  end
end

-- ── output: readiness ───────────────────────────────────────────────────────

local function strip(s)
  return (s:gsub("\27%[[%d;?]*[%a@`~]", ""):gsub("\27[%]P_][^\7\27]*\7?", ""):gsub("\27.", ""):gsub("\r", ""))
end

local prompt_pat = {
  R = "> $",
  radian = "r%$> $",
  ipython = "In %[%d+%]: $",
  python = ">>> $",
}

local pump

---@param s replstudio.Session
---@param data string[]
local function on_output(s, data)
  if s.echo_wait then
    -- The REPL has taken in the paste (it redraws it): now Enter can follow
    -- in a read of its own.
    s.echo_wait = false
    vim.defer_fn(function()
      s.enter()
    end, 5)
    return
  end
  if s.ready and not s.busy then
    return
  end
  local chunk = table.concat(data, "\n")
  -- prompt_toolkit and Python's REPL re-enable bracketed paste exactly when
  -- they start reading input again: the most reliable "ready" signal.
  local at_prompt = chunk:find("\27%[%?2004h") ~= nil
  if not at_prompt then
    local pat = prompt_pat[s.spec.kind]
    at_prompt = pat ~= nil and strip(chunk):find(pat) ~= nil
  end
  if at_prompt then
    s.ready, s.busy = true, false
    pump(s)
  end
end

-- ── input: wire formats ─────────────────────────────────────────────────────

---@param s replstudio.Session
---@param text string
local function raw(s, text)
  if s.alive then
    pcall(vim.api.nvim_chan_send, s.job, text)
  end
end

--- Plain Python older than 3.13 has no bracketed paste: multi-line code goes
--- through a file so blank lines inside blocks don't end them early.
---@param s replstudio.Session
---@param text string
local function legacy_python(s, text)
  if not text:find("\n") then
    return text .. "\r"
  end
  local path = s.dir .. "/cell.py"
  local fd = assert(io.open(path, "w"))
  fd:write(text)
  fd:close()
  return ("exec(compile(open(%q).read(), %q, 'exec'))\r"):format(path, "<replstudio>")
end

local compound = {
  ["def"] = true,
  ["class"] = true,
  ["if"] = true,
  ["for"] = true,
  ["while"] = true,
  ["with"] = true,
  ["try"] = true,
  ["async"] = true,
  ["match"] = true,
}

--- A trailing newline closes an open block (incl. one-liners like
--- `for i in x: f(i)`) so the Enter that follows executes it. Plain
--- statements go without, so the REPL shows no stray continuation line.
---@param text string
local function needs_terminator(text)
  if text:find("\n") or text:find("^%s*@") or text:find(":%s*$") then
    return true
  end
  return compound[text:match("^%s*([%a_]+)")] == true
end

---@param s replstudio.Session
function pump(s)
  if s.writing or not s.ready or s.busy or not s.alive then
    return
  end
  local text = table.remove(s.queue, 1)
  if not text then
    return
  end
  local kind = s.spec.kind
  if kind == "R" then
    -- Tabs would trigger readline completion mid-paste.
    raw(s, text:gsub("\t", "  "):gsub("\n", "\r") .. "\r")
    return pump(s)
  elseif kind == "python" and (s.spec.pyminor or 13) < 13 then
    raw(s, legacy_python(s, text))
    return pump(s)
  end
  local paste = "\27[200~" .. text .. (needs_terminator(text) and "\n" or "") .. "\27[201~"
  if kind == "python" then
    -- Python's own REPL needs Enter in a separate read from the paste (sent
    -- once it has echoed the paste), and the next paste only after it is
    -- back at the prompt.
    local sent = false
    s.enter = function()
      if sent then
        return
      end
      sent = true
      s.echo_wait, s.writing, s.busy = false, false, true
      raw(s, "\r")
    end
    s.writing, s.echo_wait = true, true
    raw(s, paste)
    vim.defer_fn(s.enter, 300) -- no echo seen: send anyway
    return
  end
  -- IPython / radian (prompt_toolkit): type-ahead safe.
  raw(s, paste .. "\r")
  return pump(s)
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

---@param s replstudio.Session
local function watch(s)
  local w = uv.new_fs_event()
  if not w then
    return
  end
  s.watcher = w
  w:start(s.dir, {}, function(err, name)
    if err or not name or not name:match("^%d+_%d+%.png$") then
      return
    end
    vim.schedule(function()
      if s.alive then
        require("replstudio.plots").on_file(s, s.dir .. "/" .. name)
      end
    end)
  end)
end

---@param s replstudio.Session
local function cleanup(s)
  s.alive = false
  if s.watcher then
    s.watcher:stop()
    s.watcher:close()
    s.watcher = nil
  end
  if M.sessions[s.key] == s then
    M.sessions[s.key] = nil
  end
  if M.last == s then
    M.last = next(M.sessions) and select(2, next(M.sessions)) or nil
  end
  vim.fn.delete(s.dir, "rf")
end

---@param lang "r"|"python"
---@param s replstudio.Session
---@param spec replstudio.Spec
---@return table<string, string>
local function hook_env(lang, s, spec)
  local env = { REPLSTUDIO_DIR = s.dir, REPLSTUDIO_WD = s.wd ~= s.root and s.wd or nil }
  if lang == "r" then
    env.R_PROFILE_USER = M.runtime .. "/r/init.R"
    env.REPLSTUDIO_R_PROFILE_USER = vim.env.R_PROFILE_USER
  else
    env.PYTHONSTARTUP = M.runtime .. "/python/replstudio_startup.py"
    env.REPLSTUDIO_PYTHONSTARTUP = vim.env.PYTHONSTARTUP
    env.MPLBACKEND = "module://replstudio_mpl"
    local pp = vim.env.PYTHONPATH
    env.PYTHONPATH = M.runtime .. "/python" .. (pp and pp ~= "" and (":" .. pp) or "")
    if spec.venv then
      env.VIRTUAL_ENV = spec.venv
      env.PATH = spec.venv .. "/bin:" .. vim.env.PATH
    end
  end
  return env
end

---@param lang "r"|"python"
---@param root string
---@param wd string
---@param spec replstudio.Spec
---@return replstudio.Session
local function start(lang, root, wd, spec)
  if not swept then
    sweep()
  end
  next_id = next_id + 1
  local s = {
    id = next_id,
    key = M.key(lang, root, wd),
    lang = lang,
    root = root,
    wd = wd,
    label = spec.label .. (wd ~= root and (" · " .. detect.short(wd, root) .. "/") or ""),
    spec = spec,
    dir = ("%s/%d-%d-%s"):format(cache_root, vim.fn.getpid(), next_id, lang),
    queue = {},
    ready = false,
    busy = false,
    writing = false,
    alive = true,
  }
  vim.fn.mkdir(s.dir, "p")
  watch(s)
  M.sessions[s.key] = s
  M.last = s

  s.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[s.buf].bufhidden = "hide"
  local layout = require("replstudio.layout")
  local win = layout.show_repl(s)
  -- Plot size is known before the first plot so it already fits the pane.
  require("replstudio.plots").write_size()

  vim.api.nvim_win_call(win, function()
    s.job = vim.fn.jobstart(spec.cmd, {
      term = true,
      cwd = root,
      env = hook_env(lang, s, spec),
      on_stdout = function(_, data)
        on_output(s, data)
      end,
      on_exit = function(_, code)
        vim.schedule(function()
          cleanup(s)
          if code ~= 0 and code ~= 129 and code ~= 143 then
            vim.notify(("%s exited with code %d"):format(spec.label, code), vim.log.levels.WARN, { title = "replstudio" })
          end
        end)
      end,
    })
  end)
  if s.job <= 0 then
    cleanup(s)
    error(("replstudio: failed to start %s"):format(table.concat(spec.cmd, " ")))
  end
  -- Custom prompts we can't recognise: stop waiting after a while.
  vim.defer_fn(function()
    if s.alive and not s.ready then
      log("no prompt seen; sending anyway")
      s.ready = true
      pump(s)
    end
  end, 8000)
  layout.decorate_repl(s, win)
  return s
end

---@param lang string
---@param root string
---@param wd string
---@return string
function M.key(lang, root, wd)
  return lang .. "\0" .. root .. "\0" .. wd
end

--- Resolve the interpreter (possibly asking about the managed venv), then
--- call `cb` with a running session.
---@param lang "r"|"python"
---@param root string
---@param wd string
---@param cb fun(s: replstudio.Session)
function M.ensure(lang, root, wd, cb)
  local s = M.sessions[M.key(lang, root, wd)]
  if s and s.alive then
    M.last = s
    return cb(s)
  end
  if lang == "r" then
    return cb(start(lang, root, wd, detect.r()))
  end
  local spec = detect.python(root)
  if spec then
    if not spec.managed and spec.venv and not detect.has_matplotlib(spec.venv) then
      require("replstudio.venv").hint_project(spec.venv)
    end
    return cb(start(lang, root, wd, spec))
  end
  require("replstudio.venv").offer(function()
    detect.clear_cache()
    cb(start(lang, root, wd, detect.python(root) or detect.system_python()))
  end)
end

--- Queue code for a session.
---@param s replstudio.Session
---@param text string
function M.send(s, text)
  s.queue[#s.queue + 1] = text
  pump(s)
  require("replstudio.layout").follow(s)
end

---@param s replstudio.Session
function M.interrupt(s)
  s.queue, s.busy, s.writing = {}, false, false
  raw(s, "\3")
end

---@param s replstudio.Session
function M.clear(s)
  raw(s, "\12")
  -- Drop the terminal scrollback too.
  local sb = vim.bo[s.buf].scrollback
  vim.bo[s.buf].scrollback = 1
  vim.bo[s.buf].scrollback = sb
end

---@param s replstudio.Session
function M.stop(s)
  if s.alive then
    vim.fn.jobstop(s.job)
  end
  cleanup(s)
  if vim.api.nvim_buf_is_valid(s.buf) then
    vim.api.nvim_buf_delete(s.buf, { force = true })
  end
end

function M.stop_all()
  for _, s in pairs(M.sessions) do
    if s.alive then
      vim.fn.jobstop(s.job)
    end
    cleanup(s)
  end
end

M._strip = strip

return M
