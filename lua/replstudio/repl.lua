--- REPL sessions: one terminal job per (language, project root, working
--- directory). The process starts in the project root (so .Rprofile / renv
--- and the project venv are found) and the hook then changes into the
--- working directory, which for a .qmd is the document's folder.
---
--- Sends are queued, and each queued write goes only once the interpreter is
--- back at a prompt. A terminal holds about 1 KB of input the program hasn't
--- read yet (macOS); typing ahead of a busy or slow reader past that drops or
--- garbles code. So R is fed one line per prompt, and code too big for one
--- write goes through a file.
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
---@field job? integer
---@field ready boolean first prompt seen
---@field busy boolean a write went out; waiting for the prompt
---@field writing boolean plain python: a paste/Enter pair is in flight
---@field echo_wait? boolean plain python: paste sent, waiting for its echo
---@field enter? fun() plain python: send the pending Enter
---@field gen integer bumped on interrupt: stale Enters are dropped
---@field queue replstudio.Item[]
---@field tail string end of the last output, for prompts split across reads
---@field nl boolean output since the last write has a newline (the Enter)
---@field prompts string[] Lua patterns matching the end of a prompt
---@field prompt_lines string[] patterns for a terminal line that is a bare prompt
---@field sent_at integer hrtime of the last write
---@field output_at integer hrtime of the last output
---@field backstop? uv.uv_timer_t
---@field watcher? uv.uv_fs_event_t
---@field alive boolean
---@field stopping? boolean we asked it to exit

---@class replstudio.Item
---@field code? string a statement or block, wire format chosen by kind
---@field line? string R: one line of a block

---@type table<string, replstudio.Session>
M.sessions = {}
--- Most recently used session: target for toggles outside code buffers.
---@type replstudio.Session|nil
M.last = nil

local next_id = 0
local swept = false

--- Longest line typed into a terminal; longer code goes through a file.
local LONG = 1000

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
    if kind == "directory" and pid and pid ~= vim.fn.getpid() then
      -- uv.kill reports failure by return value; EPERM means it's alive.
      local ok, _, code = uv.kill(pid, 0)
      if not ok and code == "ESRCH" then
        vim.fn.delete(cache_root .. "/" .. name, "rf")
      end
    end
  end
end

-- ── output: readiness ───────────────────────────────────────────────────────

local function strip(s)
  return (s:gsub("\27%[[%d;?]*[%a@`~]", ""):gsub("\27[%]P_][^\7\27]*\7?", ""):gsub("\27.", ""):gsub("\r", ""))
end

--- End of a chunk of output that shows the interpreter waiting for input.
local prompt_pat = {
  R = { "[>+] $" },
  radian = { "r%$> $" },
  ipython = { "In %[%d+%]: $" },
  python = { ">>> $", "%.%.%. $" },
}

--- A whole terminal line that is nothing but a prompt.
local prompt_line = {
  R = { "^[>+]$" },
  radian = { "^r%$>$" },
  ipython = { "^In %[%d+%]:$" },
  python = { "^>>>$", "^%.%.%.$" },
}

local pump

---@param s replstudio.Session
---@param text string
local function at_prompt(s, text)
  -- prompt_toolkit and Python's REPL re-enable bracketed paste exactly when
  -- they start reading input again: the most reliable "ready" signal.
  if text:find("\27%[%?2004h") then
    return true
  end
  text = strip(text)
  for _, pat in ipairs(s.prompts) do
    if text:find(pat) then
      return true
    end
  end
  return false
end

---@param s replstudio.Session
local function on_ready(s)
  s.ready, s.busy = true, false
  pump(s)
end

---@param s replstudio.Session
---@param data string[]
local function on_output(s, data)
  s.output_at = uv.hrtime()
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
  local text = s.tail .. chunk
  s.tail = text:sub(-64)
  -- After a write, the prompt only comes once the Enter has echoed: a line
  -- being echoed that merely contains "> " is not one.
  s.nl = s.nl or chunk:find("\n") ~= nil
  if (s.nl or not s.ready) and at_prompt(s, text) then
    on_ready(s)
  end
end

--- Last non-empty line of the terminal, trailing blanks dropped.
---@param s replstudio.Session
---@return string
local function last_line(s)
  if not vim.api.nvim_buf_is_valid(s.buf) then
    return ""
  end
  local n = vim.api.nvim_buf_line_count(s.buf)
  for i = n, math.max(1, n - 50), -1 do
    local l = vim.api.nvim_buf_get_lines(s.buf, i - 1, i, false)[1]:gsub("%s+$", "")
    if l ~= "" then
      return l
    end
  end
  return ""
end

--- Backstop while code is queued: a prompt we failed to notice would stall
--- the queue. Once output has been quiet for a second and the terminal's last
--- line is a bare prompt, the interpreter is idle.
---@param s replstudio.Session
local function backstop(s)
  if s.backstop then
    return
  end
  s.backstop = assert(uv.new_timer())
  s.backstop:start(
    500,
    500,
    vim.schedule_wrap(function()
      if not (s.alive and s.busy and #s.queue > 0) then
        if s.backstop then
          s.backstop:stop()
          s.backstop:close()
          s.backstop = nil
        end
        return
      end
      local quiet = (uv.hrtime() - s.output_at) / 1e6
      if s.output_at > s.sent_at and quiet > 1000 and not s.echo_wait then
        local l = last_line(s)
        for _, pat in ipairs(s.prompt_lines) do
          if l:find(pat) then
            log("prompt missed; resuming the queue")
            return on_ready(s)
          end
        end
      end
    end)
  )
end

-- ── input: wire formats ─────────────────────────────────────────────────────

---@param s replstudio.Session
---@param text string
local function raw(s, text)
  if s.alive and s.job then
    pcall(vim.api.nvim_chan_send, s.job, text)
  end
end

--- One write that ends in Enter; the next waits for the prompt.
---@param s replstudio.Session
---@param text string
local function submit(s, text)
  s.busy, s.tail, s.nl, s.sent_at = true, "", false, uv.hrtime()
  raw(s, text)
  if #s.queue > 0 then
    backstop(s)
  end
end

---@param s replstudio.Session
---@param name string
---@param text string
---@return string path
local function write_file(s, name, text)
  local path = detect.slash(s.dir) .. "/" .. name
  local fd = assert(io.open(path, "w"))
  fd:write(text, "\n")
  fd:close()
  return path
end

--- Code that runs from a file: the REPL only sees a one-line call. Call it
--- when the code is sent, not queued: every call reuses the same file.
---@param s replstudio.Session
---@param text string
local function via_file(s, text)
  if s.lang == "r" then
    local path = write_file(s, "cell.R", text)
    return ('source(%q, echo = TRUE, max.deparse.length = Inf, encoding = "UTF-8")'):format(path)
  end
  local path = write_file(s, "cell.py", text)
  if s.spec.kind == "ipython" then
    -- As a cell, so magics and shell lines work; `.result` is the cell's
    -- last value, shown as if typed (None, from a statement, shows nothing).
    return ("get_ipython().run_cell(open(%q, encoding='utf-8').read()).result"):format(path)
  end
  return ("exec(compile(open(%q, encoding='utf-8').read(), %q, 'exec'))"):format(path, "<replstudio>")
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

--- Longest line of `text`, in bytes.
---@param text string
local function longest(text)
  local n = 0
  for l in vim.gsplit(text, "\n", { plain = true }) do
    n = math.max(n, #l)
  end
  return n
end

--- R: queue a block line by line (each line is read at its own prompt, as
--- if typed), or as one source() when a line is too long for the console or
--- has a tab inside it (readline would complete it).
---@param s replstudio.Session
---@param text string
local function queue_r(s, text)
  local lines = vim.split(text, "\n", { plain = true })
  local file = false
  for i, l in ipairs(lines) do
    -- Leading tabs are indentation: spaces read the same.
    local lead, rest = l:match("^(%s*)(.*)$")
    lines[i] = lead:gsub("\t", "  ") .. rest
    if #lines[i] > LONG or rest:find("\t") then
      file = true
    end
  end
  if file then
    s.queue[#s.queue + 1] = { file = text }
    return
  end
  for _, l in ipairs(lines) do
    s.queue[#s.queue + 1] = { line = l }
  end
end

---@param s replstudio.Session
function pump(s)
  if s.writing or not s.ready or s.busy or not s.alive then
    return
  end
  local item = table.remove(s.queue, 1)
  if not item then
    return
  end
  if item.line then
    return submit(s, item.line .. "\r")
  elseif item.file then
    return submit(s, via_file(s, item.file) .. "\r")
  end
  local text, kind = item.code, s.spec.kind
  if kind == "R" then
    return submit(s, text .. "\r")
  end
  -- Bracketed paste: not in plain Python before 3.13, and not relied on
  -- through Windows' ConPTY.
  local paste = not detect.is_win and not (kind == "python" and (s.spec.pyminor or 13) < 13)
  local block = text:find("\n") or (s.lang == "python" and needs_terminator(text))
  if #text > 4 * LONG or longest(text) > LONG or (not paste and (block or text:find("\t"))) then
    -- Without paste, a blank line would end a block early and a tab would
    -- complete; and a very long paste outruns the terminal.
    return submit(s, via_file(s, text) .. "\r")
  elseif not paste then
    return submit(s, text .. "\r")
  end
  local pasted = "\27[200~" .. text .. (needs_terminator(text) and "\n" or "") .. "\27[201~"
  if kind == "python" then
    -- Python's own REPL needs Enter in a separate read from the paste (sent
    -- once it has echoed the paste), and the next paste only after it is
    -- back at the prompt.
    local sent, gen = false, s.gen
    s.enter = function()
      if sent or gen ~= s.gen then
        return
      end
      sent = true
      s.echo_wait, s.writing = false, false
      submit(s, "\r")
    end
    s.writing, s.echo_wait, s.sent_at = true, true, uv.hrtime()
    raw(s, pasted)
    vim.defer_fn(s.enter, 300) -- no echo seen: send anyway
    return
  end
  -- IPython / radian (prompt_toolkit).
  submit(s, pasted .. "\r")
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
  for _, field in ipairs({ "watcher", "backstop" }) do
    local h = s[field]
    if h then
      h:stop()
      h:close()
      s[field] = nil
    end
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
  local sep = detect.is_win and ";" or ":"
  local env = { REPLSTUDIO_DIR = s.dir, REPLSTUDIO_WD = s.wd ~= s.root and s.wd or nil }
  for k, v in pairs(spec.env or {}) do
    env[k] = v
  end
  if spec.path and #spec.path > 0 then
    env.PATH = table.concat(spec.path, sep) .. sep .. (vim.env.PATH or "")
  end
  if lang == "r" then
    env.R_PROFILE_USER = M.runtime .. "/r/init.R"
    env.REPLSTUDIO_R_PROFILE_USER = vim.env.R_PROFILE_USER
  else
    env.PYTHONSTARTUP = M.runtime .. "/python/replstudio_startup.py"
    env.REPLSTUDIO_PYTHONSTARTUP = vim.env.PYTHONSTARTUP
    env.MPLBACKEND = "module://replstudio_mpl"
    local pp = vim.env.PYTHONPATH
    env.PYTHONPATH = M.runtime .. "/python" .. (pp and pp ~= "" and (sep .. pp) or "")
  end
  return env
end

---@param lang "r"|"python"
---@param root string
---@param wd string
---@param spec replstudio.Spec
---@return replstudio.Session|nil
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
    gen = 0,
    tail = "",
    nl = false,
    prompts = vim.tbl_map(function(pat)
      -- Windows' ConPTY may draw a prompt's trailing space as a cursor move.
      return detect.is_win and (pat:gsub(" %$$", " ?$")) or pat
    end, prompt_pat[spec.kind] or {}),
    prompt_lines = vim.deepcopy(prompt_line[spec.kind] or {}),
    sent_at = 0,
    output_at = 0,
    alive = true,
  }
  vim.fn.mkdir(s.dir, "p")
  watch(s)
  M.sessions[s.key] = s
  M.last = s

  s.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[s.buf].bufhidden = "hide"
  local layout = require("replstudio.layout")
  local prev = layout.wins.repl and vim.api.nvim_win_is_valid(layout.wins.repl) and vim.api.nvim_win_get_buf(layout.wins.repl)
  local win = layout.show_repl(s)
  -- Plot size is known before the first plot so it already fits the pane.
  require("replstudio.plots").write_size()

  local ok, job = pcall(vim.api.nvim_win_call, win, function()
    return vim.fn.jobstart(spec.cmd, {
      term = true,
      cwd = root,
      env = hook_env(lang, s, spec),
      on_stdout = function(_, data)
        on_output(s, data)
      end,
      on_exit = function(_, code)
        vim.schedule(function()
          cleanup(s)
          if not s.stopping and code ~= 0 and code ~= 129 and code ~= 143 then
            vim.notify(("%s exited with code %d"):format(spec.label, code), vim.log.levels.WARN, { title = "replstudio" })
          end
        end)
      end,
    })
  end)
  if not ok or job <= 0 then
    -- Not executable (missing, or not on Neovim's PATH): undo, and say so.
    cleanup(s)
    if prev and vim.api.nvim_buf_is_valid(prev) and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_buf(win, prev)
    else
      layout.hide_repl()
    end
    if vim.api.nvim_buf_is_valid(s.buf) then
      vim.api.nvim_buf_delete(s.buf, { force = true })
    end
    vim.notify(
      ("Could not start %s:\n%s\nSet `%s = { cmd = { ... } }` in setup() to its full path."):format(
        table.concat(spec.cmd, " "),
        ok and "jobstart failed" or tostring(job):gsub("^.-Vim:", ""),
        lang == "r" and "r" or "python"
      ),
      vim.log.levels.ERROR,
      { title = "replstudio" }
    )
    return nil
  end
  s.job = job
  -- Custom prompts we can't recognise: stop waiting after a while, and take
  -- whatever the terminal shows now as the prompt to wait for later.
  vim.defer_fn(function()
    if s.alive and not s.ready then
      local l = last_line(s)
      log("no prompt seen; sending anyway (prompt: " .. l .. ")")
      if l ~= "" and #l <= 20 then
        table.insert(s.prompts, vim.pesc(l) .. "%s*$")
        table.insert(s.prompt_lines, "^" .. vim.pesc(l) .. "$")
      end
      on_ready(s)
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
  local function go(spec)
    local started = start(lang, root, wd, spec)
    if started then
      cb(started)
    end
  end
  if lang == "r" then
    return go(detect.r())
  end
  -- Look again: a venv may have been created since the last start.
  detect.clear_cache()
  local spec = detect.python(root)
  if spec then
    if not spec.managed and spec.venv and not detect.has_matplotlib(spec.venv) then
      require("replstudio.venv").hint_project(spec.venv)
    end
    return go(spec)
  end
  require("replstudio.venv").offer(function()
    detect.clear_cache()
    go(detect.python(root) or detect.system_python())
  end)
end

--- Queue code for a session.
---@param s replstudio.Session
---@param text string
function M.send(s, text)
  if s.spec.kind == "R" then
    queue_r(s, text)
  else
    s.queue[#s.queue + 1] = { code = text }
  end
  pump(s)
  if s.busy and #s.queue > 0 then
    backstop(s)
  end
  require("replstudio.layout").follow(s)
end

---@param s replstudio.Session
function M.interrupt(s)
  s.queue, s.busy, s.writing, s.echo_wait, s.tail = {}, false, false, false, ""
  s.gen = s.gen + 1
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
  s.stopping = true
  if s.alive and s.job then
    pcall(vim.fn.jobstop, s.job)
  end
  cleanup(s)
  if vim.api.nvim_buf_is_valid(s.buf) then
    vim.api.nvim_buf_delete(s.buf, { force = true })
  end
end

function M.stop_all()
  for _, s in pairs(M.sessions) do
    s.stopping = true
    if s.alive and s.job then
      pcall(vim.fn.jobstop, s.job)
    end
    cleanup(s)
  end
end

M._strip = strip
M._hook_env = hook_env

return M
