--- The managed fallback venv (default ~/.local/share/replstudio/venv).
---
--- Used only when a project has no venv of its own. Created on request,
--- asynchronously: the editor never blocks while uv/pip work.

local config = require("replstudio.config")

local uv = vim.uv
local M = {}

local state_file = vim.fn.stdpath("data") .. "/replstudio/state.json"
local declined_this_session = false
local hinted = {} ---@type table<string, boolean>

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "replstudio", id = "replstudio_venv" })
end

local function read_state()
  local fd = io.open(state_file, "r")
  if not fd then
    return {}
  end
  local ok, data = pcall(vim.json.decode, fd:read("*a"))
  fd:close()
  return ok and type(data) == "table" and data or {}
end

local function write_state(data)
  vim.fn.mkdir(vim.fs.dirname(state_file), "p")
  local fd = io.open(state_file, "w")
  if fd then
    fd:write(vim.json.encode(data))
    fd:close()
  end
end

---@return string
function M.path()
  return config.python.venv
end

function M.exists()
  return uv.fs_stat(M.path() .. "/bin/python") ~= nil
end

--- Run shell steps one after another; cb(ok).
---@param steps {cmd:string[], msg:string}[]
---@param cb fun(ok: boolean)
local function run(steps, cb)
  local i = 0
  local function step()
    i = i + 1
    local s = steps[i]
    if not s then
      return cb(true)
    end
    notify(s.msg .. " …")
    vim.system(s.cmd, { text = true }, function(r)
      vim.schedule(function()
        if r.code ~= 0 then
          notify(("%s failed:\n%s"):format(s.msg, vim.trim((r.stderr or "") .. (r.stdout or ""))), vim.log.levels.ERROR)
          return cb(false)
        end
        step()
      end)
    end)
  end
  step()
end

---@param pkgs string[]
---@param upgrade? boolean
local function install_step(pkgs, upgrade)
  local py = M.path() .. "/bin/python"
  local cmd
  if vim.fn.executable("uv") == 1 then
    cmd = { "uv", "pip", "install", "--python", py }
  else
    cmd = { py, "-m", "pip", "install" }
  end
  if upgrade then
    cmd[#cmd + 1] = "--upgrade"
  end
  vim.list_extend(cmd, pkgs)
  return { cmd = cmd, msg = "Installing " .. table.concat(pkgs, ", ") }
end

--- Create (or with `clear`, rebuild) the managed venv with the package list.
---@param cb? fun(ok: boolean)
---@param clear? boolean
function M.create(cb, clear)
  cb = cb or function() end
  local path = M.path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local create
  if vim.fn.executable("uv") == 1 then
    create = { "uv", "venv", path }
    if config.python.version then
      vim.list_extend(create, { "--python", config.python.version })
    end
    if clear then
      create[#create + 1] = "--clear"
    end
  else
    create = { "python3", "-m", "venv", path }
    if clear then
      create[#create + 1] = "--clear"
    end
  end
  run({
    { cmd = create, msg = "Creating " .. vim.fn.fnamemodify(path, ":~") },
    install_step(config.python.packages),
  }, function(ok)
    require("replstudio.detect").clear_cache()
    if ok then
      notify("replstudio venv ready: " .. vim.fn.fnamemodify(path, ":~"))
    end
    cb(ok)
  end)
end

---@param pkgs string[]
function M.add(pkgs)
  if #pkgs == 0 then
    return notify("usage: :ReplStudio venv add <package> …", vim.log.levels.WARN)
  end
  if not M.exists() then
    return notify("No managed venv yet. Run :ReplStudio venv install", vim.log.levels.WARN)
  end
  run({ install_step(pkgs) }, function(ok)
    if ok then
      notify("Installed " .. table.concat(pkgs, ", ") .. ". Restart the Python REPL to use them.")
    end
  end)
end

function M.update()
  if not M.exists() then
    return notify("No managed venv yet. Run :ReplStudio venv install", vim.log.levels.WARN)
  end
  run({ install_step(config.python.packages, true) }, function(ok)
    if ok then
      notify("Managed venv updated.")
    end
  end)
end

--- Ask once whether to create the managed venv, then call `cb` (with or
--- without it; the caller falls back to the system interpreter).
---@param cb fun()
function M.offer(cb)
  if declined_this_session or read_state().never then
    return cb()
  end
  local where = vim.fn.fnamemodify(M.path(), ":~")
  local choices = { "Yes, create it", "Not now (use system python)", "Never ask again" }
  vim.ui.select(choices, {
    prompt = ("No project venv. Create the replstudio venv at %s (%s)?"):format(
      where,
      table.concat(config.python.packages, ", ")
    ),
  }, function(_, i)
    if i == 1 then
      M.create(function()
        cb()
      end)
    else
      if i == 3 then
        local st = read_state()
        st.never = true
        write_state(st)
      end
      declined_this_session = true
      cb()
    end
  end)
end

--- One-time nudge when a project venv can't draw plots.
---@param venv string
function M.hint_project(venv)
  if hinted[venv] then
    return
  end
  hinted[venv] = true
  local tool = vim.fn.executable("uv") == 1 and ("uv pip install --python %s"):format(vim.fn.fnamemodify(venv, ":~"))
    or (vim.fn.fnamemodify(venv, ":~") .. "/bin/pip install")
  notify(("This project's venv has no matplotlib; plots won't show.\n%s ipython matplotlib plotnine"):format(tool), vim.log.levels.WARN)
end

return M
