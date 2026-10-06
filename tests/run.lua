-- Zero-dependency test runner. From the repo root:
--   nvim --headless -u NONE -i NONE -l tests/run.lua
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local total, failed = 0, 0

---@param got any
---@param want any
---@param label string
function _G.eq(got, want, label)
  total = total + 1
  local a, b = vim.inspect(got), vim.inspect(want)
  if a ~= b then
    failed = failed + 1
    io.stderr:write(("FAIL  %s\n        got:  %s\n        want: %s\n"):format(label, a, b))
  end
end

--- Load a fixture into a scratch buffer with the given filetype.
---@param name string
---@param ft string
---@return integer
function _G.fixture_buf(name, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn.readfile("tests/fixtures/" .. name))
  vim.bo[buf].filetype = ft
  return buf
end

for _, spec in ipairs(vim.fn.glob("tests/*_spec.lua", false, true)) do
  dofile(spec)
end

io.stdout:write(("%d/%d assertions passed\n"):format(total - failed, total))
os.exit(failed == 0 and 0 or 1)
