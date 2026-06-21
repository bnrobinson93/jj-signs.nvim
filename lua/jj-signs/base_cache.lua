local M = {}
local store = {} --- @type table<string, string>

--- base_rev is included in the key so a change_base never serves a stale base:
--- two revisions resolving to different commits already differ, but keying on
--- base_rev too keeps the default ("@-") namespace cleanly separated. It is an
--- optional trailing arg (default "@-") so existing 3-arg call sites are unchanged.
--- @param filepath string
--- @param parent_change_id string
--- @param parent_commit_id string
--- @param base_rev string?
--- @return string
local function make_key(filepath, parent_change_id, parent_commit_id, base_rev)
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
function M.get(filepath, parent_change_id, parent_commit_id, base_rev)
  return store[make_key(filepath, parent_change_id, parent_commit_id, base_rev)]
end

--- base_rev is a trailing optional arg (after text) to preserve the existing
--- 4-arg set() call shape.
--- @param filepath string
--- @param parent_change_id string
--- @param parent_commit_id string
--- @param text string
--- @param base_rev string?
function M.set(filepath, parent_change_id, parent_commit_id, text, base_rev)
  store[make_key(filepath, parent_change_id, parent_commit_id, base_rev)] = text
end

--- Build the cache key for a (filepath, parent_change_id, parent_commit_id, base_rev)
--- tuple. Exposed so callers (e.g. evict_stale) can construct active-key sets.
--- @param filepath string
--- @param parent_change_id string
--- @param parent_commit_id string
--- @param base_rev string?
--- @return string
function M.key(filepath, parent_change_id, parent_commit_id, base_rev)
  return make_key(filepath, parent_change_id, parent_commit_id, base_rev)
end

--- Remove entries whose keys are not in active_keys set.
--- @param active_keys table<string, true>
function M.evict_stale(active_keys)
  for k in pairs(store) do
    if not active_keys[k] then
      store[k] = nil
    end
  end
end

--- For testing
function M._clear() store = {} end

return M
