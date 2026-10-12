-- Interpreter discovery on each OS, with fake install trees: the platform
-- flags, PATH lookup and installer env vars are swapped for the test.
local config = require("replstudio.config")
local detect = require("replstudio.detect")

local tmp = vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)/[^/]*$")) .. "/rs_platform_" .. vim.uv.hrtime()
local function touch(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines or {}, path)
  vim.uv.fs_chmod(path, 493) -- 0755: an executable
  return path
end

local saved = {
  is_win = detect.is_win,
  is_mac = detect.is_mac,
  exepath = detect._exepath,
  env = {},
}
local vars = { "VIRTUAL_ENV", "CONDA_PREFIX", "CONDA_DEFAULT_ENV", "LOCALAPPDATA", "ProgramFiles", "ProgramFiles(x86)", "APPDATA", "R_HOME" }
for _, k in ipairs(vars) do
  saved.env[k] = vim.env[k]
  vim.env[k] = nil
end
local on_path = {} ---@type table<string, string>
detect._exepath = function(name)
  return on_path[name] or ""
end
config.setup({ python = { venv = tmp .. "/managed" } })

-- ── Windows ─────────────────────────────────────────────────────────────────
detect.is_win, detect.is_mac = true, false

-- project venv: Scripts\python.exe, Scripts\ipython.exe
local proj = tmp .. "/proj"
touch(proj .. "/.venv/Scripts/python.exe")
touch(proj .. "/.venv/Scripts/ipython.exe")
vim.fn.writefile({ "version_info = 3.12.1" }, proj .. "/.venv/pyvenv.cfg")
detect.clear_cache()
local spec = detect.python(proj)
eq({ spec.kind, spec.cmd[1], spec.pyminor }, { "ipython", proj .. "/.venv/Scripts/ipython.exe", 12 }, "win: venv Scripts\\ layout")
eq({ spec.path, spec.env }, { { proj .. "/.venv/Scripts" }, { VIRTUAL_ENV = proj .. "/.venv" } }, "win: venv PATH and env")

-- an activated (non-base) conda env beats the project venv
local conda = tmp .. "/miniconda3/envs/geo"
touch(conda .. "/python.exe")
touch(conda .. "/conda-meta/python-3.11.9-h123_0.json")
vim.env.CONDA_PREFIX, vim.env.CONDA_DEFAULT_ENV = conda, "geo"
detect.clear_cache()
spec = detect.python(proj)
eq({ spec.label, spec.kind, spec.cmd[1], spec.pyminor }, { "py · conda:geo", "python", conda .. "/python.exe", 11 }, "win: conda env")
eq(vim.tbl_contains(spec.path, conda .. "/Library/bin"), true, "win: conda Library\\bin on PATH (DLLs)")
eq(spec.env, { CONDA_PREFIX = conda }, "win: CONDA_PREFIX set")

-- conda base: the project venv wins; with nothing else, base is used
local base = tmp .. "/miniconda3"
touch(base .. "/python.exe")
vim.fn.mkdir(base .. "/condabin", "p")
vim.fn.mkdir(base .. "/conda-meta", "p")
vim.env.CONDA_PREFIX, vim.env.CONDA_DEFAULT_ENV = base, "base"
detect.clear_cache()
eq(detect.python(proj).venv, proj .. "/.venv", "win: project venv beats conda base")
eq(detect.python(tmp .. "/empty").label, "py · conda:base", "win: conda base as the last resort")
vim.env.CONDA_PREFIX, vim.env.CONDA_DEFAULT_ENV = nil, nil

-- R: newest Rterm.exe under Program Files, off PATH
local pf = tmp .. "/Program Files"
vim.env.ProgramFiles = pf
touch(pf .. "/R/R-4.3.2/bin/x64/Rterm.exe")
touch(pf .. "/R/R-4.10.0/bin/x64/Rterm.exe")
eq(detect.find_r(), pf .. "/R/R-4.10.0/bin/x64/Rterm.exe", "win: newest R under Program Files")
spec = detect.r()
eq({ spec.kind, spec.cmd[1], spec.path }, { "R", pf .. "/R/R-4.10.0/bin/x64/Rterm.exe", { pf .. "/R/R-4.10.0/bin/x64" } }, "win: R spec, its dir on PATH")
-- a per-user R install
vim.env.ProgramFiles = tmp .. "/nothing"
vim.env.LOCALAPPDATA = tmp .. "/Local"
touch(tmp .. "/Local/Programs/R/R-4.4.1/bin/x64/Rterm.exe")
eq(detect.find_r(), tmp .. "/Local/Programs/R/R-4.4.1/bin/x64/Rterm.exe", "win: per-user R install")
-- R_HOME first
vim.env.R_HOME = tmp .. "/rhome"
touch(tmp .. "/rhome/bin/x64/Rterm.exe")
eq(detect.find_r(), tmp .. "/rhome/bin/x64/Rterm.exe", "win: R_HOME")
vim.env.R_HOME = nil
-- on PATH beats everything
on_path.Rterm = "C:\\R\\bin\\Rterm.exe"
detect._exepath = function(name)
  return on_path[name] or ""
end
local exe = vim.fn.executable
vim.fn.executable = function(p)
  return p == "C:\\R\\bin\\Rterm.exe" and 1 or exe(p)
end
eq(detect.find_r(), "C:/R/bin/Rterm.exe", "win: PATH first, backslashes made forward")
vim.fn.executable = exe
on_path.Rterm = nil

-- Python: newest python.org install; Store alias only as a last resort
touch(tmp .. "/Local/Programs/Python/Python39/python.exe")
touch(tmp .. "/Local/Programs/Python/Python312/python.exe")
spec = detect.find_python()
eq({ spec.cmd[1], spec.pyminor }, { tmp .. "/Local/Programs/Python/Python312/python.exe", 12 }, "win: newest python.org Python")
vim.fn.delete(tmp .. "/Local/Programs/Python", "rf")
touch(tmp .. "/Local/Microsoft/WindowsApps/python.exe")
eq(detect.find_python().cmd[1], tmp .. "/Local/Microsoft/WindowsApps/python.exe", "win: Store alias when nothing else")
on_path.py = tmp .. "/py.exe"
eq(detect.find_python().cmd, { tmp .. "/py.exe", "-3" }, "win: py launcher beats the Store alias")
on_path.py = nil

-- REPL environment: ; separators
local env = require("replstudio.repl")._hook_env("python", { dir = "D", wd = "W", root = "W" }, { path = { "A", "B" }, env = { VIRTUAL_ENV = "V" } })
eq(vim.startswith(env.PATH, "A;B;"), true, "win: PATH joined with ;")
eq(env.PYTHONPATH:find(";", 1, true) ~= nil or vim.env.PYTHONPATH == nil, true, "win: PYTHONPATH separator")
eq(env.VIRTUAL_ENV, "V", "env from the spec")

-- ── Linux ───────────────────────────────────────────────────────────────────
detect.is_win, detect.is_mac = false, false
vim.env.R_HOME = tmp .. "/linux-r"
touch(tmp .. "/linux-r/bin/R")
eq(detect.find_r(), tmp .. "/linux-r/bin/R", "linux: R_HOME when R is not on PATH")
on_path.R = "/usr/bin/R"
vim.fn.executable = function(p)
  return p == "/usr/bin/R" and 1 or exe(p)
end
eq(detect.find_r(), "/usr/bin/R", "linux: R on PATH")
eq(detect.r().path, nil, "linux: R on PATH needs no PATH change")
vim.fn.executable = exe
on_path.R = nil
vim.env.R_HOME = nil

-- ── shared ──────────────────────────────────────────────────────────────────
-- demoted stubs come last, versions sort numerically
touch(tmp .. "/s/stub/python3")
touch(tmp .. "/s/v/3.9/python3")
touch(tmp .. "/s/v/3.10/python3")
local function stub(p)
  return p:find("/stub/", 1, true) ~= nil
end
eq(detect.find_exe({}, { tmp .. "/s/stub/python3", tmp .. "/s/v/*/python3" }, stub), tmp .. "/s/v/3.10/python3", "stub demoted, 3.10 newer than 3.9")
eq(detect.find_exe({}, { tmp .. "/s/stub/python3" }, stub), tmp .. "/s/stub/python3", "stub used when alone")
eq(detect._exe_minor("C:/Users/x/AppData/Local/Programs/Python/Python311/python.exe"), 11, "Windows install path minor")
eq(detect._exe_minor("/home/x/.local/share/uv/python/cpython-3.12.4-linux-x86_64-gnu/bin/python3"), 12, "uv path minor")
eq(detect._env_minor(conda), 11, "conda-meta minor")

detect.is_win, detect.is_mac, detect._exepath = saved.is_win, saved.is_mac, saved.exepath
for _, k in ipairs(vars) do
  vim.env[k] = saved.env[k]
end
detect.clear_cache()
config.setup({})
vim.fn.delete(tmp, "rf")
