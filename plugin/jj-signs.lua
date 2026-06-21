if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("jj-signs.nvim requires Neovim >= 0.10", vim.log.levels.WARN)
  return
end

-- No auto-setup. User must call require("jj-signs").setup()

-- Register :JJSigns up front so the command (and its completion) is available
-- before setup() runs. The command callback lazily calls setup({}) on first use
-- if the user has not initialized jj-signs yet.
require("jj-signs.cli").create_command()
