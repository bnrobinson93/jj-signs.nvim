local M = {}

--- @param expected any
--- @param actual any
function M.eq(expected, actual)
  assert.are.same(expected, actual)
end

--- @param a any
--- @param b any
function M.neq(a, b)
  assert.are_not.same(a, b)
end

--- @param path string
--- @param lines string[]
function M.write_file(path, lines)
  local f = assert(io.open(path, "w"))
  f:write(table.concat(lines, "\n") .. "\n")
  f:close()
end

--- @param path string
--- @return string[]
function M.read_file(path)
  local f = assert(io.open(path, "r"))
  local content = f:read("*a")
  f:close()
  local lines = {}
  for l in content:gmatch("[^\n]+") do
    lines[#lines + 1] = l
  end
  return lines
end

--- Create a temp jj repo with an initial committed file.
--- Returns the repo root path and the tracked file path.
--- @return string root, string filepath
function M.setup_jj_repo()
  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, "p")

  local function run(cmd)
    local result = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then
      error("Command failed: " .. table.concat(cmd, " ") .. "\n" .. result)
    end
    return result
  end

  run({ "jj", "init", "--git", tmpdir })
  local filepath = tmpdir .. "/test.txt"
  M.write_file(filepath, { "line1", "line2", "line3" })
  run({ "jj", "--repository", tmpdir, "describe", "-m", "initial" })

  return tmpdir, filepath
end

return M
