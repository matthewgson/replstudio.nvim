local send = require("replstudio.send")

---@param buf integer
---@param row integer 1-based line the cursor is on
local function pick(buf, row)
  local p = send.pick_statement(buf, row - 1)
  if not p then
    return nil
  end
  return { p.lang, p.text, p.next_row + 1 }
end

-- ── R ────────────────────────────────────────────────────────────────────────
local r = fixture_buf("sample.R", "r")
eq(pick(r, 1), { "r", "library(ggplot2)", 4 }, "R: simple call, skips comment+blank to next")
eq(pick(r, 2), { "r", "x <- 1:10", 5 }, "R: on comment -> next statement")
eq(pick(r, 3), { "r", "x <- 1:10", 5 }, "R: on blank -> next statement")
eq(pick(r, 7)[2], "f <- function(a, b = 2) {\n  y <- a + b\n\n  y * 2\n}", "R: inside function body sends whole def")
eq(pick(r, 7)[3], 10, "R: advance past function")
eq(pick(r, 11)[2], "df <- mtcars |>\n  subset(cyl > 4) |>\n  transform(kpl = mpg * 0.425)", "R: pipe chain")
eq(pick(r, 15)[2], "ggplot(df, aes(wt, mpg)) +\n  geom_point() +\n  facet_wrap(~cyl)", "R: ggplot + chain from last line")
eq(pick(r, 16), { "r", "a <- 1; b <- 2", 17 }, "R: two statements on one line")
eq(pick(r, 18)[2], "for (i in 1:3) {\n  print(i)\n}", "R: for loop")
eq(pick(r, 22)[2], 'if (x[1] > 0) {\n  "pos"\n} else {\n  "neg"\n}', "R: if/else")
eq(pick(r, 25), nil, "R: past last statement")

-- ── Python ───────────────────────────────────────────────────────────────────
local py = fixture_buf("sample.py", "python")
eq(pick(py, 1), { "python", "import matplotlib.pyplot as plt", 3 }, "py: import")
eq(pick(py, 4)[2], "@decorator\ndef f(a):\n    b = a + 1\n\n    return b * 2", "py: comment line -> decorated def")
eq(pick(py, 10)[2], "@decorator\ndef f(a):\n    b = a + 1\n\n    return b * 2", "py: blank line inside def")
eq(pick(py, 11)[3], 14, "py: advance past def")
eq(pick(py, 15)[2], "for i in range(3):\n    print(i)", "py: for loop body")
eq(pick(py, 17)[2], "plt.plot(x,\n         x)", "py: multi-line call")
eq(pick(py, 21)[2], "if x:\n    pass\nelse:\n    pass", "py: if/else from else branch")

-- ── cells ────────────────────────────────────────────────────────────────────
local cells = fixture_buf("cells.py", "python")
local c = send.pick_cell(cells, 3)
eq({ c.text, c.next_row }, { "a = 1\nb = 2", 5 }, "cell: middle cell (next_row is 0-based)")
c = send.pick_cell(cells, 0)
eq({ c.text, c.next_row }, { "import numpy as np", 2 }, "cell: before first marker")
c = send.pick_cell(cells, 5)
eq({ c.text, c.next_row }, { "c = 3", 6 }, "cell: last cell")

-- ── Quarto ───────────────────────────────────────────────────────────────────
local q = fixture_buf("doc.qmd", "quarto")
eq(pick(q, 5), nil, "qmd: prose")
eq(pick(q, 7), { "r", "x <- 1", 9 }, "qmd: on opening fence -> first statement")
eq(pick(q, 10), { "r", "y <- function() {\n  2\n}", 17 }, "qmd: last statement jumps to next chunk body")
eq(pick(q, 12), nil, "qmd: on closing fence")
eq(pick(q, 18), { "python", "z = math.pi", 19 }, "qmd: last chunk, last statement -> closing fence")
eq(pick(q, 23), nil, "qmd: non-executable bash block")
eq(send.lang_at(q, 17), "python", "qmd: lang_at python chunk")
c = send.pick_cell(q, 9)
eq({ c.lang, c.text, c.next_row }, { "r", "x <- 1\ny <- function() {\n  2\n}", 16 }, "qmd: whole chunk")

-- ── normalize ────────────────────────────────────────────────────────────────
eq(send.normalize("    a = 1\n    if a:\n        b\n\n"), "a = 1\nif a:\n    b", "normalize: dedent + trim")

-- ── split (python cells) ─────────────────────────────────────────────────────
eq(
  send.split("python", "a = 1\n\n# c\ndef f():\n    x = 1\n\n    return x\n(\n  f()\n)\nb = 2; c = 3"),
  { "a = 1", "def f():\n    x = 1\n\n    return x", "(\n  f()\n)", "b = 2; c = 3" },
  "split: statements, comment skipped, blank line kept inside def"
)
