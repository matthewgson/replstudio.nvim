local config = require("replstudio.config")
local detect = require("replstudio.detect")

local tmp = vim.uv.fs_realpath(vim.fn.tempname():match("^(.*)/[^/]*$")) .. "/rs_wd_" .. vim.uv.hrtime()
local function touch(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines or {}, path)
end
local function open(path, ft)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.bo[buf].filetype = ft
  return buf
end

config.setup({})
local proj = tmp .. "/proj"
touch(proj .. "/.git/HEAD")
touch(proj .. "/reports/q1/report.qmd")
touch(proj .. "/scripts/clean.R")

local qmd = open(proj .. "/reports/q1/report.qmd", "quarto")
local root = detect.root(qmd)
eq(root, proj, "qmd: project root still found via .git")
eq(detect.workdir(qmd, root), proj .. "/reports/q1", "qmd: works in the document's folder")

local script = open(proj .. "/scripts/clean.R", "r")
eq(detect.workdir(script, detect.root(script)), proj, "R script: works in the project root")

config.setup({ quarto = { cwd = "root" } })
eq(detect.workdir(qmd, root), proj, "qmd with quarto.cwd = 'root': project root")
config.setup({})

-- Quarto project that renders from the project dir
local qp = tmp .. "/qproj"
touch(qp .. "/_quarto.yml", { "project:", "  type: website", "  execute-dir: project" })
touch(qp .. "/posts/a/index.qmd")
local post = open(qp .. "/posts/a/index.qmd", "quarto")
eq(detect.workdir(post, detect.root(post)), qp, "qmd in project with execute-dir: project")

-- Quarto project without that setting: still the document's folder
local qp2 = tmp .. "/qproj2"
touch(qp2 .. "/_quarto.yml", { "project:", "  type: book" })
touch(qp2 .. "/ch/1.qmd")
local ch = open(qp2 .. "/ch/1.qmd", "quarto")
eq(detect.workdir(ch, detect.root(ch)), qp2 .. "/ch", "qmd in project without execute-dir")

vim.fn.delete(tmp, "rf")
