--- Defaults and the merged options. Read options as `config.<key>`.

local M = {}

local is_win = vim.fn.has("win32") == 1
local home = (vim.uv.os_homedir() or vim.env.HOME or ""):gsub("\\", "/")
--- Where the managed venv lives: XDG data home, or %LOCALAPPDATA% on Windows.
local data_home = vim.env.XDG_DATA_HOME
  or (is_win and (vim.env.LOCALAPPDATA or (home .. "/AppData/Local")):gsub("\\", "/"))
  or (home .. "/.local/share")

---@class replstudio.Config
M.defaults = {
  --- Prefix for the <leader> group ("interpreter"). Set to false to skip
  --- those mappings. (<leader>r is left to quarto-render.nvim.)
  prefix = "<leader>i",
  --- "studio" | "side" | "focus"
  layout = "studio",
  --- Fractions of the editor: plots column width, REPL height.
  size = { plots = 0.38, repl = 0.30 },
  --- Plot float used by the "focus" layout and by zoom.
  float = { width = 0.45, height = 0.55 },
  --- Open the plot pane when a new plot arrives.
  auto_open_plots = true,
  --- Multiplier on the auto-detected plot DPI (bigger text and lines).
  plot_scale = 1.0,
  quarto = {
    --- Working directory for code sent from a .qmd:
    ---   "file"  the document's folder, like `quarto render` (a project's
    ---           `execute-dir: project` in _quarto.yml is honoured)
    ---   "root"  the project root, like scripts
    cwd = "file",
  },
  r = {
    --- Full command, e.g. { "radian" }. nil: radian if installed, else R,
    --- found on PATH or where installers put it (Rterm.exe on Windows).
    cmd = nil,
  },
  python = {
    --- Full command. nil: resolved from the project venv / managed venv.
    cmd = nil,
    --- Managed fallback venv, used when the project has none.
    venv = data_home .. "/replstudio/venv",
    packages = { "ipython", "matplotlib", "plotnine", "pandas", "numpy" },
    --- Passed to `uv venv --python` when creating the managed venv.
    version = nil,
  },
  parquet = {
    --- Rows read per chunk; more load as you scroll, rows far away are
    --- dropped. "auto": 20,000 cells ÷ columns shown (at most 60), i.e.
    --- 100–5,000 rows, so a chunk lays out without a visible pause.
    rows = "auto",
    --- Widest a column gets, in screen cells; longer values end in "…".
    max_width = 32,
  },
  debug = false,
}

M.options = vim.deepcopy(M.defaults)

---@param opts? table
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return setmetatable(M, {
  __index = function(_, key)
    return M.options[key]
  end,
})
