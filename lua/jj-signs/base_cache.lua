local M = {}
local store = {} --- @type table<string, string>

--- @param filepath string
--- @param parent_change_id string
--- @param parent_commit_id string
--- @return string
local function make_key(filepath, parent_change_id, parent_commit_id)
  return filepath .. "|" .. (parent_change_id or "") .. "|" .. (parent_commit_id or "")
end

--- @param filepath string
--- @param parent_change_id string
--- @param parent_commit_id string
--- @return string?
function M.get(filepath, parent_change_id, parent_commit_id)
  return store[make_key(filepath, parent_change_id, parent_commit_id)]
end

--- @param filepath string
--- @param parent_change_id string
--- @param parent_commit_id string
--- @param text string
function M.set(filepath, parent_change_id, parent_commit_id, text)
  store[make_key(filepath, parent_change_id, parent_commit_id)] = text
end

--- Build the cache key for a (filepath, parent_change_id, parent_commit_id) tuple.
--- Exposed so callers (e.g. evict_stale) can construct active-key sets.
--- @param filepath string
--- @param parent_change_id string
--- @param parent_commit_id string
--- @return string
function M.key(filepath, parent_change_id, parent_commit_id)
  return make_key(filepath, parent_change_id, parent_commit_id)
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
