--- @class JJSigns.CacheEntry
--- @field root             string
--- @field change_id        string
--- @field bookmark         string?  bookmark pointing at @ (first if several), "" when none
--- @field description      string?  first line of @'s description, "" when empty
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
--- @field diffing           boolean?  a diff is in flight for this buffer (per-buffer diff lock)
--- @field diff_pending       boolean?  a refresh arrived mid-diff; re-run once the current diff finishes
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

-- Shared base-content store: a file's content as of a comparison revision, keyed
-- by (filepath, parent ids, base_rev). Distinct from the per-buffer entries above
-- — two buffers on the same file+parent share one fetch. Kept in this module so
-- eviction (base_gc) can be owned here instead of leaking the key format to
-- callers.
local base_store = {} --- @type table<string, string>

--- base_rev is part of the key so a change_base never serves a stale base: two
--- revisions resolving to different commits already differ, but keying on base_rev
--- too keeps the default ("@-") namespace cleanly separated.
--- @param base_rev string?
--- @return string
local function base_key(filepath, parent_change_id, parent_commit_id, base_rev)
  return filepath
    .. "|" .. (parent_change_id or "")
    .. "|" .. (parent_commit_id or "")
    .. "|" .. (base_rev or "@-")
end

--- @param filepath string
--- @param parent_change_id string
--- @param parent_commit_id string
--- @param base_rev string?
--- @return string?
function M.base_get(filepath, parent_change_id, parent_commit_id, base_rev)
  return base_store[base_key(filepath, parent_change_id, parent_commit_id, base_rev)]
end

--- @param filepath string
--- @param parent_change_id string
--- @param parent_commit_id string
--- @param text string
--- @param base_rev string?
function M.base_set(filepath, parent_change_id, parent_commit_id, text, base_rev)
  base_store[base_key(filepath, parent_change_id, parent_commit_id, base_rev)] = text
end

--- Evict base-content entries no longer referenced by any live buffer. Walks the
--- per-buffer entries, computes the base key each would look up, and drops every
--- stored key outside that active set. The key format never leaves this module.
--- Call after clearing a detached buffer's entry.
function M.base_gc()
  local active = {}
  for bufnr, entry in pairs(cache) do
    if entry.parent_change_id and entry.parent_commit_id then
      local fp = vim.api.nvim_buf_get_name(bufnr)
      active[base_key(fp, entry.parent_change_id, entry.parent_commit_id, entry.base_rev)] = true
    end
  end
  for k in pairs(base_store) do
    if not active[k] then base_store[k] = nil end
  end
end

--- For testing
function M.base_clear() base_store = {} end

return M
