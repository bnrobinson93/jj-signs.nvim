local M = {}

-- Override in tests
M._uv = nil

local function get_uv()
  return M._uv or vim.uv or vim.loop
end

-- Expose for test inspection / teardown
local watchers = {} --- @type table<string, { handle: any, refs: integer, cb: function, timer: any }>
M._watchers = watchers

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

  local target = root .. "/.jj/repo/op_heads/"
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
