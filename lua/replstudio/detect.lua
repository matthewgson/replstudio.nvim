--- Project root and interpreter resolution.
---
--- Hot path: everything here is stat()s and small file reads, never a
--- subprocess, and Python results are cached per root.

local config = require("replstudio.config")

local uv = vim.uv
local M = {}

---@class replstudio.Spec
---@field cmd string[]
---@field kind "R"|"radian"|"ipython"|"python"
---@field label string winbar text
---@field venv? string
---@field pyminor? integer Python 3.<minor>, nil when unknown
---@field managed? boolean the replstudio fallback venv

---@type table<string, replstudio.Spec|false>
local cache = {}

local function exists(path)
  return uv.fs_stat(path) ~= nil
end

local markers = {
  [".venv"] = true,
  ["venv"] = true,
  ["pyproject.toml"] = true,
  ["uv.lock"] = true,
  ["renv.lock"] = true,
  ["DESCRIPTION"] = true,
  [".git"] = true,
}

---@param buf integer
---@return string
function M.root(buf)
  local root = vim.fs.root(buf, function(name)
    return markers[name] or name:match("%.Rproj$") ~= nil
  end)
  if root then
    return root
  end
  local name = vim.api.nvim_buf_get_name(buf)
  return name ~= "" and vim.fs.dirname(name) or uv.cwd()
end

--- `execute-dir: project` in a Quarto project's _quarto.yml.
---@param qroot string
local function executes_in_project(qroot)
  local fd = io.open(qroot .. "/_quarto.yml", "r")
  if not fd then
    return false
  end
  local text = fd:read("*a")
  fd:close()
  return ("\n" .. text):find("\n%s*execute%-dir:%s*[\"']?project") ~= nil
end

--- Working directory for code sent from this buffer. Quarto renders a
--- document from its own folder (or the project's, with `execute-dir:
--- project`), so the REPL does the same; scripts work from the project root.
---@param buf integer
---@param root string
---@return string
function M.workdir(buf, root)
  if vim.bo[buf].filetype ~= "quarto" or config.quarto.cwd == "root" then
    return root
  end
  local file = vim.api.nvim_buf_get_name(buf)
  if file == "" then
    return root
  end
  local qroot = vim.fs.root(buf, "_quarto.yml")
  if qroot and executes_in_project(qroot) then
    return qroot
  end
  return vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(file, ":p")))
end

--- "~/x/.venv" style label relative to root when possible.
local function short(path, root)
  if path == root then
    return "."
  end
  if root and vim.startswith(path, root .. "/") then
    return path:sub(#root + 2)
  end
  return vim.fn.fnamemodify(path, ":~")
end

--- Python minor version of a venv from pyvenv.cfg.
---@param venv string
---@return integer|nil
local function venv_minor(venv)
  local fd = io.open(venv .. "/pyvenv.cfg", "r")
  if not fd then
    return nil
  end
  local text = fd:read("*a")
  fd:close()
  local minor = text:match("version_info%s*=%s*3%.(%d+)") or text:match("\nversion%s*=%s*3%.(%d+)")
  return tonumber(minor)
end

--- Python minor version of an executable, from its resolved path
--- (Homebrew/uv/pyenv all keep "python3.X" in the real path).
---@param exe string
---@return integer|nil
local function exe_minor(exe)
  local real = uv.fs_realpath(exe) or exe
  return tonumber(real:match("python@?3%.(%d+)") or real:match("3%.(%d+)/bin/python"))
end

---@param venv string
---@param root? string
---@param label? string
---@return replstudio.Spec
local function from_venv(venv, root, label)
  local ipy = venv .. "/bin/ipython"
  local spec = {
    venv = venv,
    pyminor = venv_minor(venv),
    label = label or short(venv, root),
  }
  if exists(ipy) then
    spec.cmd, spec.kind = { ipy, "--no-banner", "--no-confirm-exit" }, "ipython"
  else
    spec.cmd, spec.kind = { venv .. "/bin/python" }, "python"
  end
  spec.label = "py · " .. spec.label .. (spec.kind == "ipython" and " (ipython)" or "")
  return spec
end

--- True when the venv has matplotlib (one glob over site-packages).
---@param venv string
function M.has_matplotlib(venv)
  return vim.fn.glob(venv .. "/lib/python3*/site-packages/matplotlib", false, true)[1] ~= nil
end

--- Project or managed venv, nil when neither exists.
---@param root string
---@return replstudio.Spec|nil
function M.python(root)
  local hit = cache[root]
  if hit ~= nil then
    return hit or nil
  end
  local spec ---@type replstudio.Spec|nil
  local py = config.python
  if py.cmd then
    local kind = py.cmd[1]:match("ipython") and "ipython" or "python"
    spec = { cmd = py.cmd, kind = kind, label = "py · custom" }
    if kind == "python" then
      local exe = vim.fn.exepath(py.cmd[1])
      spec.pyminor = exe_minor(exe ~= "" and exe or py.cmd[1])
    end
  elseif vim.env.VIRTUAL_ENV and exists(vim.env.VIRTUAL_ENV .. "/bin/python") then
    spec = from_venv(vim.env.VIRTUAL_ENV, root)
  else
    for _, name in ipairs({ ".venv", "venv" }) do
      if exists(root .. "/" .. name .. "/bin/python") then
        spec = from_venv(root .. "/" .. name, root)
        break
      end
    end
    if not spec and exists(py.venv .. "/bin/python") then
      spec = from_venv(py.venv, nil, "replstudio venv")
      spec.managed = true
    end
  end
  cache[root] = spec or false
  return spec
end

--- System interpreter, used when the user declines the managed venv.
---@return replstudio.Spec
function M.system_python()
  local ipy = vim.fn.exepath("ipython")
  if ipy ~= "" then
    return { cmd = { ipy, "--no-banner", "--no-confirm-exit" }, kind = "ipython", label = "py · system ipython" }
  end
  local exe = vim.fn.exepath("python3")
  exe = exe ~= "" and exe or "python3"
  return { cmd = { exe }, kind = "python", pyminor = exe_minor(exe), label = "py · system python3" }
end

---@return replstudio.Spec
function M.r()
  if config.r.cmd then
    return { cmd = config.r.cmd, kind = config.r.cmd[1]:match("radian") and "radian" or "R", label = "R · custom" }
  end
  if vim.fn.exepath("radian") ~= "" then
    return { cmd = { "radian", "--quiet" }, kind = "radian", label = "R · radian" }
  end
  return { cmd = { "R", "--quiet", "--no-save" }, kind = "R", label = "R" }
end

function M.clear_cache()
  cache = {}
end

M.short = short
M._exe_minor = exe_minor
M._venv_minor = venv_minor

return M
