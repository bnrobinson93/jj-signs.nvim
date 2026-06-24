-- Regression: the op-log watcher must ignore filesystem touches that do not
-- change the op head. Every `jj` command (even read-only `jj log`/`jj diff`)
-- rewrites/touches `.jj/repo/op_heads/heads/` without creating a new operation;
-- firing a refresh on those touches makes the refresh spawn more `jj` commands,
-- which touch the dir again — an endless spawn loop. The watcher must compare the
-- op-head signature (directory contents) and only fire when it actually changes.
local watcher = require("jj-signs.watcher")

describe("watcher op-head dedup", function()
  local fake_uv, fse_handles, pending_timers, real_schedule, current_names

  local function flush_timers()
    local snapshot = pending_timers
    pending_timers = {}
    for _, t in ipairs(snapshot) do
      if t._running and t._cb then t:stop(); t._cb() end
    end
  end

  before_each(function()
    fse_handles    = {}
    pending_timers = {}
    current_names  = { "opA" }  -- starting op head
    real_schedule  = vim.schedule
    vim.schedule   = function(f) f() end

    fake_uv = {
      new_timer = function()
        return {
          _running = false, _cb = nil,
          start = function(self, _, _, cb) self._running = true; self._cb = cb; table.insert(pending_timers, self); return 0 end,
          stop  = function(self) self._running = false end,
          close = function(self) self._running = false end,
        }
      end,
      new_fs_event = function()
        return {
          _started = false, _callback = nil,
          start = function(self, _, _, cb) self._started = true; self._callback = cb; table.insert(fse_handles, self); return 0 end,
          stop  = function(self) self._started = false end,
          close = function(self) self._started = false end,
        }
      end,
      new_fs_poll = function()
        return {
          start = function() return 0 end, stop = function() end, close = function() end,
        }
      end,
      fs_scandir = function(_) return { idx = 0, names = vim.deepcopy(current_names) } end,
      fs_scandir_next = function(st) st.idx = st.idx + 1; return st.names[st.idx] end,
    }
    watcher._uv = fake_uv
  end)

  after_each(function()
    for k in pairs(watcher._watchers) do watcher._watchers[k] = nil end
    for k in pairs(watcher._op_gen) do watcher._op_gen[k] = nil end
    for k in pairs(watcher._op_cid) do watcher._op_cid[k] = nil end
    watcher._uv  = nil
    vim.schedule = real_schedule
  end)

  it("does not fire cb when the op head is unchanged (spurious touch)", function()
    local root, called = "/repo/x", 0
    watcher.start(root, function() called = called + 1 end)

    -- Touch with the SAME op head (jj read command rewriting the dir).
    fse_handles[1]._callback(nil, "heads", {})
    flush_timers()
    assert.equals(0, called)
  end)

  it("fires cb when the op head actually changes", function()
    local root, called = "/repo/y", 0
    watcher.start(root, function() called = called + 1 end)

    current_names = { "opB" }   -- a real new operation landed
    fse_handles[1]._callback(nil, "heads", {})
    flush_timers()
    assert.equals(1, called)
  end)

  it("does not bump the op generation on a spurious touch", function()
    local root = "/repo/z"
    watcher.start(root, function() end)
    local gen0 = watcher.op_gen(root)

    fse_handles[1]._callback(nil, "heads", {})  -- same op head
    flush_timers()
    assert.equals(gen0, watcher.op_gen(root))
  end)
end)
