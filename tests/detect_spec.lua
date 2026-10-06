local config = require("replstudio.config")
local detect = require("replstudio.detect")

local tmp = vim.fn.tempname()
local function touch(path)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({}, path)
end

local managed = tmp .. "/managed"
local saved_env = vim.env.VIRTUAL_ENV
vim.env.VIRTUAL_ENV = nil
config.setup({ python = { venv = managed } })

-- ── project venv beats the managed venv ─────────────────────────────────────
local proj = tmp .. "/proj"
touch(proj .. "/pyproject.toml")
touch(proj .. "/.venv/bin/python")
touch(proj .. "/.venv/bin/ipython")
vim.fn.writefile({ "home = /x", "version_info = 3.12.4" }, proj .. "/.venv/pyvenv.cfg")
touch(managed .. "/bin/python")
local spec = detect.python(proj)
eq({ spec.kind, spec.venv, spec.pyminor, spec.managed }, { "ipython", proj .. "/.venv", 12, nil }, "project .venv wins")
eq(spec.cmd[1], proj .. "/.venv/bin/ipython", "ipython from the venv")

-- ── `venv/` also counts; plain python when no ipython ───────────────────────
local proj2 = tmp .. "/proj2"
touch(proj2 .. "/venv/bin/python")
spec = detect.python(proj2)
eq({ spec.kind, spec.venv }, { "python", proj2 .. "/venv" }, "venv/ dir, plain python")

-- ── no project venv: managed venv ───────────────────────────────────────────
local bare = tmp .. "/bare"
vim.fn.mkdir(bare, "p")
spec = detect.python(bare)
eq({ spec.managed, spec.label }, { true, "py · replstudio venv" }, "managed venv fallback")

-- ── nothing at all: nil (caller offers to create the managed venv) ──────────
vim.fn.delete(managed, "rf")
detect.clear_cache()
eq(detect.python(bare), nil, "no venv anywhere")

-- ── root detection ──────────────────────────────────────────────────────────
touch(proj .. "/src/pkg/mod.py")
local buf = vim.fn.bufadd(proj .. "/src/pkg/mod.py")
eq(vim.uv.fs_realpath(detect.root(buf)), vim.uv.fs_realpath(proj), "root from nested file")

-- ── version parsing ─────────────────────────────────────────────────────────
eq(detect._exe_minor("/opt/homebrew/Cellar/python@3.14/3.14.7/bin/python3.14"), 14, "brew path minor")

vim.env.VIRTUAL_ENV = saved_env
config.setup({})
vim.fn.delete(tmp, "rf")
