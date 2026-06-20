local M = {}
local cache = require("jj-signs.cache")

--- Poll until cond() returns true or timeout_ms elapses.
--- @param cond fun(): boolean
--- @param timeout_ms integer
--- @return boolean  true if condition met
function M.wait_until(cond, timeout_ms)
  return vim.wait(timeout_ms, cond, 10) == true
end

--- Wait until buffer's cache entry has dirty == false.
--- @param bufnr integer
--- @param timeout_ms integer
--- @return boolean
function M.wait_for_refresh(bufnr, timeout_ms)
  return M.wait_until(function()
    local e = cache.get(bufnr)
    return e ~= nil and e.dirty == false
  end, timeout_ms or 2000)
end

return M
