--- Project root and interpreter resolution, on macOS, Linux and Windows.
---
--- Root lookup is the hot path: stat()s and small file reads, never a
--- subprocess. Interpreter lookup runs once per REPL start: PATH first, then
--- the places installers put R and Python, for when Neovim's PATH lacks them
--- (Neovim started from the macOS Dock, or R on Windows, which installs off
--- PATH).

local config = require("replstudio.config")

local uv = vim.uv
local M = {}

--- Platform; tests flip it to exercise the Windows layouts.
M.is_win = vim.fn.has("win32") == 1
M.is_mac = vim.fn.has("mac") == 1

--- PATH lookup (tests stub it).
M._exepath = vim.fn.exepath

---@class replstudio.Spec
---@field cmd string[]
---@field kind "R"|"radian"|"ipython"|"python"
---@field label string winbar text
---@field venv? string environment prefix (venv or conda)
---@field pyminor? integer Python 3.<minor>, nil when unknown
---@field managed? boolean the replstudio fallback venv
---@field path? string[] directories put first on the REPL's PATH
---@field env? table<string, string> extra environment for the REPL

---@type table<string, replstudio.Spec|false>
local cache = {}

local function exists(path)
  return uv.fs_stat(path) ~= nil
end

--- Forward slashes: Windows takes them, and they need no escaping when a
--- path is written into R or Python code.
---@param path string
---@return string
function M.slash(path)
  return M.is_win and (path:gsub("\\", "/")) or path
end

local function home()
  return M.slash(uv.os_homedir() or vim.env.HOME or vim.env.USERPROFILE or "")
end

---@param name string
---@return string|nil
local function env(name)
  local v = vim.env[name]
  return v and v ~= "" and M.slash(v) or nil
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

-- ── executables ─────────────────────────────────────────────────────────────

--- Numbers in a path, for "newest version first" ordering.
---@param path string
---@return integer[]
local function version_key(path)
  local key = {}
  for d in path:gmatch("%d+") do
    key[#key + 1] = tonumber(d)
  end
  return key
end

---@param a string
---@param b string
local function newer(a, b)
  local ka, kb = version_key(a), version_key(b)
  for i = 1, math.max(#ka, #kb) do
    local x, y = ka[i] or -1, kb[i] or -1
    if x ~= y then
      return x > y
    end
  end
  return false
end

--- First executable found: each name on PATH, then each glob (newest match
--- first). Paths for which `demote` is true (OS stubs that only offer to
--- install the real thing) are used only when nothing else turns up.
---@param names string[]
---@param globs string[]
---@param demote? fun(path: string): boolean
---@return string|nil
function M.find_exe(names, globs, demote)
  local late
  local function take(path)
    if not path or path == "" or vim.fn.executable(path) ~= 1 then
      return nil
    end
    path = M.slash(path)
    if demote and demote(path) then
      late = late or path
      return nil
    end
    return path
  end
  for _, name in ipairs(names) do
    local hit = take(M._exepath(name))
    if hit then
      return hit
    end
  end
  for _, pattern in ipairs(globs) do
    local found = vim.fn.glob(pattern, false, true)
    table.sort(found, newer)
    for _, path in ipairs(found) do
      local hit = take(path)
      if hit then
        return hit
      end
    end
  end
  return late
end

-- ── Python environments ─────────────────────────────────────────────────────

--- Interpreter of a venv or conda env: bin/ on Unix; Scripts\ (venv) or the
--- env's root (conda) on Windows.
---@param prefix string
---@return string|nil
function M.env_python(prefix)
  local candidates = M.is_win and { "/Scripts/python.exe", "/python.exe" } or { "/bin/python", "/bin/python3" }
  for _, rel in ipairs(candidates) do
    if exists(prefix .. rel) then
      return prefix .. rel
    end
  end
end

---@param prefix string
---@return string|nil
local function env_ipython(prefix)
  local rel = M.is_win and "/Scripts/ipython.exe" or "/bin/ipython"
  return exists(prefix .. rel) and prefix .. rel or nil
end

--- Directories an activated env puts first on PATH (conda on Windows also
--- needs its Library dirs there, or compiled packages fail to load DLLs).
---@param prefix string
---@return string[]
function M.env_path(prefix)
  if not M.is_win then
    return { prefix .. "/bin" }
  end
  if exists(prefix .. "/conda-meta") then
    return {
      prefix,
      prefix .. "/Library/mingw-w64/bin",
      prefix .. "/Library/usr/bin",
      prefix .. "/Library/bin",
      prefix .. "/Scripts",
      prefix .. "/bin",
    }
  end
  return { prefix .. "/Scripts" }
end

--- Python minor version of an env, from files only.
---@param prefix string
---@return integer|nil
local function env_minor(prefix)
  local fd = io.open(prefix .. "/pyvenv.cfg", "r")
  if fd then
    local text = fd:read("*a")
    fd:close()
    local minor = text:match("version_info%s*=%s*3%.(%d+)") or text:match("\nversion%s*=%s*3%.(%d+)")
    if minor then
      return tonumber(minor)
    end
  end
  -- conda: conda-meta/python-3.12.4-<build>.json
  local meta = vim.fn.glob(prefix .. "/conda-meta/python-3.*.json", false, true)[1]
  if meta then
    return tonumber(meta:match("python%-3%.(%d+)"))
  end
  local lib = vim.fn.glob(prefix .. "/lib/python3.*", false, true)[1]
  return lib and tonumber(lib:match("python3%.(%d+)$")) or nil
end

--- Python minor version of an executable, from its resolved path
--- (Homebrew/uv/pyenv keep "python3.X" in it, Windows installs "Python3X").
---@param exe string
---@return integer|nil
local function exe_minor(exe)
  local real = M.slash(uv.fs_realpath(exe) or exe)
  return tonumber(
    real:match("python@?3%.(%d+)")
      or real:match("3%.(%d+)/bin/python")
      or real:match("cpython%-3%.(%d+)")
      or real:match("[Pp]ython3(%d+)/[^/]*$")
  )
end

---@param prefix string
---@param root? string
---@param label? string
---@return replstudio.Spec|nil
local function from_env(prefix, root, label)
  prefix = M.slash(prefix)
  local py = M.env_python(prefix)
  if not py then
    return nil
  end
  local conda = exists(prefix .. "/conda-meta")
  local spec = {
    venv = prefix,
    pyminor = env_minor(prefix),
    label = label or short(prefix, root),
    path = M.env_path(prefix),
    env = conda and { CONDA_PREFIX = prefix } or { VIRTUAL_ENV = prefix },
  }
  local ipy = env_ipython(prefix)
  if ipy then
    spec.cmd, spec.kind = { ipy, "--no-banner", "--no-confirm-exit" }, "ipython"
  else
    spec.cmd, spec.kind = { py }, "python"
  end
  spec.label = "py · " .. spec.label .. (spec.kind == "ipython" and " (ipython)" or "")
  return spec
end

--- True when the env has matplotlib (one glob over site-packages).
---@param venv string
function M.has_matplotlib(venv)
  return vim.fn.glob(venv .. "/lib/python3*/site-packages/matplotlib", false, true)[1] ~= nil
    or vim.fn.glob(venv .. "/Lib/site-packages/matplotlib", false, true)[1] ~= nil
end

--- The conda env the shell activated, and whether it is the base install.
---@return string|nil prefix, boolean base
local function conda_env()
  local prefix = env("CONDA_PREFIX")
  if not prefix then
    return nil, false
  end
  return prefix, vim.env.CONDA_DEFAULT_ENV == "base" or exists(prefix .. "/condabin")
end

--- Environment for a project, in order: the shell's activated venv or conda
--- env, the project's .venv/venv, the managed venv, then conda's base.
--- nil when none exists (the caller offers to create the managed venv).
---@param root string
---@return replstudio.Spec|nil
function M.python(root)
  local hit = cache[root]
  if hit ~= nil then
    return hit or nil
  end
  local spec ---@type replstudio.Spec|nil
  local py = config.python
  local conda, base = conda_env()
  if py.cmd then
    local kind = py.cmd[1]:match("ipython") and "ipython" or "python"
    spec = { cmd = py.cmd, kind = kind, label = "py · custom" }
    if kind == "python" then
      local exe = M._exepath(py.cmd[1])
      spec.pyminor = exe_minor(exe ~= "" and exe or py.cmd[1])
    end
  end
  spec = spec or (env("VIRTUAL_ENV") and from_env(env("VIRTUAL_ENV"), root))
  if not spec and conda and not base then
    spec = from_env(conda, root, "conda:" .. vim.fs.basename(conda))
  end
  for _, name in ipairs({ ".venv", "venv" }) do
    spec = spec or from_env(root .. "/" .. name, root)
  end
  if not spec then
    spec = from_env(py.venv, nil, "replstudio venv")
    if spec then
      spec.managed = true
    end
  end
  if not spec and conda then
    spec = from_env(conda, root, "conda:base")
  end
  cache[root] = spec or false
  return spec
end

--- Places Python installers put python, for when PATH has none.
---@return string[]
local function python_globs()
  local h = home()
  if M.is_win then
    local local_ = env("LOCALAPPDATA") or (h .. "/AppData/Local")
    return {
      local_ .. "/Programs/Python/Python3*/python.exe", -- python.org, per user
      (env("ProgramFiles") or "C:/Program Files") .. "/Python3*/python.exe", -- python.org, all users
      (env("APPDATA") or (h .. "/AppData/Roaming")) .. "/uv/python/cpython-3*/python.exe",
      h .. "/miniforge3/python.exe",
      h .. "/miniconda3/python.exe",
      h .. "/anaconda3/python.exe",
      local_ .. "/Microsoft/WindowsApps/python.exe", -- Store alias
    }
  end
  local globs = {}
  if M.is_mac then
    globs = {
      "/opt/homebrew/bin/python3",
      "/usr/local/bin/python3",
      "/Library/Frameworks/Python.framework/Versions/Current/bin/python3", -- python.org
    }
  else
    globs = { "/usr/local/bin/python3", "/home/linuxbrew/.linuxbrew/bin/python3" }
  end
  return vim.list_extend(globs, {
    h .. "/.pyenv/shims/python3",
    h .. "/.local/bin/python3",
    h .. "/.local/share/uv/python/cpython-3*/bin/python3",
    h .. "/miniforge3/bin/python3",
    h .. "/miniconda3/bin/python3",
    h .. "/anaconda3/bin/python3",
    "/usr/bin/python3",
  })
end

--- Stubs that only offer to install Python: macOS's /usr/bin/python3 asks
--- for the Command Line Tools, Windows' WindowsApps alias opens the Store.
---@param path string
local function python_stub(path)
  if M.is_win then
    return path:find("/WindowsApps/", 1, true) ~= nil
  end
  return M.is_mac and path == "/usr/bin/python3"
end

--- A plain Python interpreter outside any env (also used to create the
--- managed venv when uv is missing).
---@return replstudio.Spec|nil
function M.find_python()
  local exe = M.find_exe(M.is_win and { "python" } or { "python3", "python" }, python_globs(), python_stub)
  if (not exe or python_stub(exe)) and M.is_win and M._exepath("py") ~= "" then
    -- The py launcher (python.org installs) picks the newest Python 3.
    return { cmd = { M.slash(M._exepath("py")), "-3" }, kind = "python", label = "py · py -3" }
  end
  if not exe then
    return nil
  end
  return { cmd = { exe }, kind = "python", pyminor = exe_minor(exe), label = "py · system python" }
end

--- System interpreter, used when the user declines the managed venv.
---@return replstudio.Spec
function M.system_python()
  local plain = M.find_python()
  local ipy = M._exepath("ipython")
  if ipy == "" and plain and #plain.cmd == 1 then
    -- An IPython installed next to that Python (off PATH like it).
    local sibling = vim.fs.dirname(plain.cmd[1]) .. (M.is_win and "/Scripts/ipython.exe" or "/ipython")
    if M.is_win and not exists(sibling) then
      sibling = vim.fs.dirname(plain.cmd[1]) .. "/ipython.exe"
    end
    ipy = vim.fn.executable(sibling) == 1 and sibling or ""
  end
  if ipy ~= "" then
    return {
      cmd = { M.slash(ipy), "--no-banner", "--no-confirm-exit" },
      kind = "ipython",
      label = "py · system ipython",
    }
  end
  return plain or { cmd = { M.is_win and "python" or "python3" }, kind = "python", label = "py · python" }
end

-- ── R ───────────────────────────────────────────────────────────────────────

--- R's console executable. Windows installs R off PATH, under Program Files
--- (or LOCALAPPDATA for a per-user install); Rterm.exe is its console.
---@return string|nil
function M.find_r()
  local r_home = env("R_HOME")
  if M.is_win then
    local globs = {}
    if r_home then
      vim.list_extend(globs, { r_home .. "/bin/x64/Rterm.exe", r_home .. "/bin/Rterm.exe" })
    end
    for _, base in ipairs({
      env("ProgramFiles") or "C:/Program Files",
      (env("LOCALAPPDATA") or (home() .. "/AppData/Local")) .. "/Programs",
      env("ProgramFiles(x86)") or "C:/Program Files (x86)",
    }) do
      vim.list_extend(globs, { base .. "/R/R-*/bin/x64/Rterm.exe", base .. "/R/R-*/bin/Rterm.exe" })
    end
    return M.find_exe({ "Rterm", "R" }, globs)
  end
  local globs = {}
  if r_home then
    globs[1] = r_home .. "/bin/R"
  end
  vim.list_extend(globs, {
    "/opt/homebrew/bin/R",
    "/usr/local/bin/R",
    "/Library/Frameworks/R.framework/Resources/bin/R", -- CRAN installer (macOS)
    "/usr/bin/R",
    "/opt/R/*/bin/R", -- Posit / rig builds (Linux)
    home() .. "/.local/bin/R",
  })
  return M.find_exe({ "R" }, globs)
end

---@return string|nil
local function find_radian()
  local h = home()
  local globs = { h .. "/.local/bin/radian" } -- pipx, uv tool
  if M.is_win then
    local local_ = env("LOCALAPPDATA") or (h .. "/AppData/Local")
    globs = {
      h .. "/.local/bin/radian.exe",
      (env("APPDATA") or (h .. "/AppData/Roaming")) .. "/Python/Python3*/Scripts/radian.exe",
      local_ .. "/Programs/Python/Python3*/Scripts/radian.exe",
    }
  elseif M.is_mac then
    vim.list_extend(globs, { "/opt/homebrew/bin/radian", "/usr/local/bin/radian" })
  end
  return M.find_exe({ "radian" }, globs)
end

---@return replstudio.Spec
function M.r()
  if config.r.cmd then
    return { cmd = config.r.cmd, kind = config.r.cmd[1]:match("radian") and "radian" or "R", label = "R · custom" }
  end
  local r = M.find_r()
  -- R found off PATH goes on the REPL's PATH: radian and system("R ...")
  -- look for it there.
  local path = r and M._exepath(vim.fs.basename(r)) == "" and { vim.fs.dirname(r) } or nil
  local radian = find_radian()
  if radian and (r or M.is_win) then -- radian finds R on Windows by itself
    return { cmd = { radian, "--quiet" }, kind = "radian", label = "R · radian", path = path }
  end
  return { cmd = { r or "R", "--quiet", "--no-save" }, kind = "R", label = "R", path = path }
end

function M.clear_cache()
  cache = {}
end

M.short = short
M._exe_minor = exe_minor
M._env_minor = env_minor

return M
