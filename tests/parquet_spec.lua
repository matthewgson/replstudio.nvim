local config = require("replstudio.config")
local parquet = require("replstudio.parquet")

-- ── type kinds ──────────────────────────────────────────────────────────────
eq(
  vim.tbl_map(parquet._kind, { "BIGINT", "DECIMAL(18,2)", "DOUBLE", "INTERVAL", "TIMESTAMP WITH TIME ZONE" }),
  { "num", "num", "num", "time", "time" },
  "numeric and temporal kinds"
)
eq(
  vim.tbl_map(parquet._kind, { "VARCHAR", "BOOLEAN", "BIGINT[]", "STRUCT(a INTEGER)", "MAP(VARCHAR, INTEGER)", "BIT" }),
  { "str", "bool", "nested", "nested", "nested", "other" },
  "string, bool, nested, other kinds"
)

-- ── sql quoting ─────────────────────────────────────────────────────────────
local sql = parquet._sql("/tmp/it's.parquet", 50)
eq(sql:find("'/tmp/it''s.parquet'", 1, true) ~= nil, true, "single quote doubled")
eq(sql:find("LIMIT 50", 1, true) ~= nil, true, "row limit")

-- ── parsing duckdb -list output ─────────────────────────────────────────────
local F, R, N = "\31", "\30", "\1"
local out = table.concat({
  "1234" .. F .. "2",
  "id" .. F .. "BIGINT" .. F .. "YES" .. F .. N .. F .. N .. F .. N,
  "note" .. F .. "VARCHAR" .. F .. "YES" .. F .. N .. F .. N .. F .. N,
  "1" .. F .. "a\nb",
  "2" .. F .. N,
}, R) .. R
local res = parquet._parse(out)
eq(res.total, 1234, "total rows")
eq(res.cols, {
  { name = "id", type = "bigint", kind = "num" },
  { name = "note", type = "varchar", kind = "str" },
}, "columns, lowercased types")
eq(res.rows, { { "1", "a\nb" }, { "2", N } }, "rows keep embedded newlines and NULL")
eq(parquet._parse("IO Error"), nil, "garbage is nil")

-- ── layout ──────────────────────────────────────────────────────────────────
config.setup({ parquet = { max_width = 8 } })
local view = {
  cols = {
    { name = "n", type = "bigint", kind = "num" },
    { name = "s", type = "varchar", kind = "str" },
  },
  rows = { { "5", "a long value here" }, { "123", N }, { "7", "日本語テキスト" } },
}
local lines, marks = parquet._layout(view)
eq(view.widths, { 6, 8 }, "widths: header type vs capped value")
eq(view.starts, { 1, 10 }, "display starts")
eq(lines[1], " n      │ s       ", "names line")
eq(lines[2], " bigint │ varchar ", "types line")
eq(lines[3], "────────┼─────────", "rule")
eq(lines[4], "      5 │ a long …", "numbers right, long text truncated")
eq(lines[5], "    123 │ NULL    ", "NULL shown")
eq(lines[6], "      7 │ 日本語… ", "wide chars truncated by display width")
local null = vim.tbl_filter(function(m)
  return m[4] == "ReplStudioParquetNull"
end, marks)
eq(null, { { 4, 12, 16, "ReplStudioParquetNull" } }, "NULL highlight byte span")
eq(
  vim.tbl_map(function(l)
    return vim.fn.strdisplaywidth(l)
  end, lines),
  { 18, 18, 18, 18, 18, 18 },
  "every line the same display width"
)

-- Control characters stay on one line.
view.rows = { { "1", "a\tb\nc" } }
lines = parquet._layout(view)
eq(lines[4], "      1 │ a→b↵c  ", "tab and newline shown as glyphs")

config.setup({})
