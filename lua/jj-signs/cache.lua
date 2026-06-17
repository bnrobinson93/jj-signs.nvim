--- @class JJSigns.CacheEntry
--- @field root       string
--- @field change_id  string
--- @field mtime      number
--- @field hunks      JJSigns.Hunk[]
--- @field dirty      boolean

--- @type table<integer, JJSigns.CacheEntry>
local cache = {}

local M = {}

--- @param bufnr integer
--- @return JJSigns.CacheEntry?
function M.get(bufnr)
  return cache[bufnr]
end

--- @param bufnr integer
--- @param entry JJSigns.CacheEntry
function M.set(bufnr, entry)
  cache[bufnr] = entry
end

--- @param bufnr integer
function M.invalidate(bufnr)
  local entry = cache[bufnr]
  if entry then
    entry.dirty = true
  end
end

--- @param bufnr integer
function M.clear(bufnr)
  cache[bufnr] = nil
end

function M.invalidate_all()
  for _, entry in pairs(cache) do
    entry.dirty = true
  end
end

--- @param bufnr integer
--- @return boolean
function M.has(bufnr)
  return cache[bufnr] ~= nil
end

return M
