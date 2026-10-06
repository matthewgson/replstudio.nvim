if vim.g.loaded_replstudio then
  return
end
vim.g.loaded_replstudio = 1

if vim.fn.has("nvim-0.11") == 0 then
  vim.notify("replstudio.nvim requires Neovim 0.11 or newer", vim.log.levels.ERROR)
  return
end

local group = vim.api.nvim_create_augroup("replstudio", { clear = true })

vim.api.nvim_create_autocmd("FileType", {
  group = group,
  pattern = { "r", "python", "quarto" },
  callback = function(ev)
    require("replstudio").attach(ev.buf)
  end,
})

-- Parquet is binary: show a read-only table instead of reading the bytes.
vim.api.nvim_create_autocmd("BufReadCmd", {
  group = group,
  pattern = "*.parquet",
  callback = function(ev)
    require("replstudio.parquet").open(ev.buf)
  end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    local repl = package.loaded["replstudio.repl"]
    if repl then
      repl.stop_all()
    end
    local plots = package.loaded["replstudio.plots"]
    if plots then
      plots.cleanup()
    end
  end,
})

vim.api.nvim_create_user_command("ReplStudio", function(cmd)
  require("replstudio").command(cmd.args)
end, {
  nargs = "*",
  desc = "replstudio: start | stop | restart | info | plots | layout [mode] | venv …",
  complete = function(arglead, line)
    return require("replstudio").complete(arglead, line)
  end,
})

-- Buffers opened before the plugin loaded (lazy-loading on FileType).
-- Scheduled so a plugin manager's setup(opts) call (e.g. a custom prefix)
-- lands first.
vim.schedule(function()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      require("replstudio").attach(buf)
    end
  end
end)
