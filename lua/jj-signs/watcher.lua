local M = {}

-- Override in tests
M._uv = nil

local function get_uv()
  return M._uv or vim.uv or vim.loop
end

-- Expose for test inspection / teardown
local watchers = {} --- @type table<string, { handle: any, refs: integer, cb: function, timer: any }>
M._watchers = watchers

-- Op generation + last-read change_id per root. This is the single source of
-- truth for "has @ moved since we last read it". It lives here, not in init.lua,
-- because init is loaded under two module names (`jj-signs` and `jj-signs.init`)
-- and a local there splits into two tables — a watcher fire seen by one instance
-- would be invisible to refresh() on the other. The watcher module has one
-- canonical require name, so this state is genuinely shared.
local op_gen = {} --- @type table<string, integer>
local op_cid = {} --- @type table<string, { gen: integer, change_id: string }>
M._op_gen = op_gen
M._op_cid = op_cid

--- Current op generation for a root (0 if never observed).
--- @param root string
--- @return integer
function M.op_gen(root)
  return op_gen[root] or 0
end

--- Cached @ change_id for a root, but only if it was read at the current
--- generation. A later op bump invalidates it automatically (returns nil).
--- @param root string
--- @return string?
function M.cached_change_id(root)
  local c = op_cid[root]
  if c and c.gen == (op_gen[root] or 0) then return c.change_id end
  return nil
end

--- Record a change_id read at generation `gen`. If the watcher bumped the
--- generation while the read was in flight, this stamp is already stale and
--- cached_change_id will report a miss, so the next refresh re-reads.
--- @param root string
--- @param change_id string
--- @param gen integer
function M.record_change_id(root, change_id, gen)
  op_cid[root] = { gen = gen, change_id = change_id }
end

--- Bump the generation for every active root, forcing the next refresh to
--- re-read @'s change_id. Called on repo-internal writes that may have moved @.
function M.invalidate()
  for root in pairs(op_cid) do
    op_gen[root] = (op_gen[root] or 0) + 1
  end
end

local DEBOUNCE_MS   = 200
local POLL_INTERVAL = 500

local function fire_debounced(root)
  local w = watchers[root]
  if not w then return end
  local uv = get_uv()
  if w.timer then
    w.timer:stop()
    w.timer:close()
    w.timer = nil
  end
  local timer = uv.new_timer()
  w.timer = timer
  timer:start(DEBOUNCE_MS, 0, function()
    local still_w = watchers[root]
    if still_w and still_w.timer == timer then
      still_w.timer:stop()
      still_w.timer:close()
      still_w.timer = nil
    end
    vim.schedule(function()
      local final_w = watchers[root]
      if final_w then
        -- Bump before the cb so refresh() (driven by the cb) sees the new
        -- generation and re-reads @'s change_id.
        op_gen[root] = (op_gen[root] or 0) + 1
        final_w.cb()
      end
    end)
  end)
end

--- Start (or ref-count) a watcher for `root`. Calls `cb()` after any op lands.
--- @param root string
--- @param cb function
function M.start(root, cb)
  if watchers[root] then
    watchers[root].refs = watchers[root].refs + 1
    watchers[root].cb   = cb
    return
  end

  local target = root .. "/.jj/repo/op_heads/heads/"
  local entry  = { handle = nil, refs = 1, cb = cb, timer = nil }
  watchers[root] = entry

  local uv = get_uv()

  local function start_poll()
    local ph = uv.new_fs_poll()
    entry.handle = ph
    ph:start(target, POLL_INTERVAL, function(poll_err)
      if not poll_err and watchers[root] then
        fire_debounced(root)
      end
    end)
  end

  local fse = uv.new_fs_event()
  local ok = fse:start(target, { recursive = false, watch_entry = false }, function(fse_err, _, _)
    if fse_err then
      if entry.handle == fse then
        fse:stop()
        fse:close()
        entry.handle = nil
        start_poll()
      end
      return
    end
    if watchers[root] then
      fire_debounced(root)
    end
  end)

  if ok then
    entry.handle = fse
  else
    pcall(function() fse:close() end)
    start_poll()
  end
end

--- Decrement ref count for `root`. Stops and closes the handle when refs reach 0.
--- @param root string
function M.stop(root)
  local w = watchers[root]
  if not w then return end
  w.refs = w.refs - 1
  if w.refs > 0 then return end

  if w.timer then
    w.timer:stop()
    w.timer:close()
    w.timer = nil
  end

  if w.handle then
    w.handle:stop()
    w.handle:close()
    w.handle = nil
  end

  watchers[root] = nil
end

return M
