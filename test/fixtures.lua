local M = {}

--- Create a temp jj repo with a committed file. Returns root path.
--- @return string root
function M.make_jj_repo()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  vim.fn.system({ "jj", "git", "init", root })
  -- Write a file and commit it
  local filepath = root .. "/test.lua"
  local f = assert(io.open(filepath, "w"))
  f:write("-- original\nlocal x = 1\n")
  f:close()
  vim.fn.system({ "jj", "--repository", root, "describe", "-m", "initial" })
  vim.fn.system({ "jj", "--repository", root, "new" })
  return root
end

--- Remove temp repo
--- @param root string
function M.cleanup(root)
  vim.fn.delete(root, "rf")
end

return M
