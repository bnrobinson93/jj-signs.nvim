--- @class JJSigns.CacheEntry
--- @field root             string
--- @field change_id        string
--- @field mtime            number
--- @field hunks            JJSigns.Hunk[]
--- @field dirty            boolean
--- @field hunk_index       { start: integer, vend: integer, sign_type: string }[]?
--- @field base_text        string?  cached base-revision content; nil = not yet fetched or invalidated
--- @field base_rev         string?  revision to compare against; default "@-" (parent of @)
--- @field parent_change_id string?  change_id of base_rev when base_text was fetched
--- @field parent_commit_id string?  commit_id of base_rev when base_text was fetched
--- @field parent_gen        integer?  op generation at which parent ids were last resolved
--- @field update_on_view    boolean?  true when refresh was deferred because buffer had no window
--- @field dirty_range { first: integer, last: integer }?  dirty line range (0-indexed), nil = unknown

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

--- @param root string
function M.invalidate_all_in_root(root)
  for _, entry in pairs(cache) do
    if entry.root == root then
      -- Drop the cached base content too: an op landed and base_rev may now
      -- resolve to a different revision, so the next refresh must re-fetch it.
      entry.dirty     = true
      entry.base_text = nil
    end
  end
end

--- @return table<integer, JJSigns.CacheEntry>
function M.all()
  return cache
end

--- @param bufnr integer
--- @return boolean
function M.has(bufnr)
  return cache[bufnr] ~= nil
end

return M
