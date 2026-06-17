if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("jj-signs.nvim requires Neovim >= 0.10", vim.log.levels.WARN)
  return
end

-- No auto-setup. User must call require("jj-signs").setup()
