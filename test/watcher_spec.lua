local watcher = require("jj-signs.watcher")

describe("watcher", function()
  local fake_uv
  local fse_handles       --- @type table list of fake fs_event handles created
  local pending_timers    --- @type table list of fake timers created
  local real_schedule

  local function flush_timers()
    -- Execute all running timer callbacks (simulates time passing past DEBOUNCE_MS)
    local snapshot = pending_timers
    pending_timers = {}
    for _, t in ipairs(snapshot) do
      if t._running and t._cb then
        t:stop()
        t._cb()
      end
    end
  end

  before_each(function()
    fse_handles    = {}
    pending_timers = {}

    real_schedule  = vim.schedule
    vim.schedule   = function(f) f() end  -- run immediately in tests

    fake_uv = {
      new_timer = function()
        local t = {
          _running = false,
          _cb      = nil,
          start = function(self, _, _, cb)
            self._running = true
            self._cb      = cb
            table.insert(pending_timers, self)
            return 0
          end,
          stop  = function(self) self._running = false end,
          close = function(self) self._running = false end,
        }
        return t
      end,

      new_fs_event = function()
        local fse = {
          _started  = false,
          _callback = nil,
          start = function(self, _, _, cb)
            self._started  = true
            self._callback = cb
            table.insert(fse_handles, self)
            return 0
          end,
          stop  = function(self) self._started = false end,
          close = function(self) self._started = false end,
        }
        return fse
      end,

      new_fs_poll = function()
        local ph = {
          _started  = false,
          _callback = nil,
          start = function(self, _, _, cb)
            self._started  = true
            self._callback = cb
            return 0
          end,
          stop  = function(self) self._started = false end,
          close = function(self) self._started = false end,
        }
        return ph
      end,
    }

    watcher._uv = fake_uv
  end)

  after_each(function()
    -- Force-clear all watcher state so tests don't bleed
    for k in pairs(watcher._watchers) do
      watcher._watchers[k] = nil
    end
    pending_timers = {}
    fse_handles    = {}
    watcher._uv    = nil
    vim.schedule   = real_schedule
  end)

  it("start creates handle and calls cb after debounce fires", function()
    local root   = "/repo/a"
    local called = 0
    watcher.start(root, function() called = called + 1 end)

    assert.is_not_nil(fse_handles[1])
    assert.is_true(fse_handles[1]._started)

    -- Trigger an fs_event change
    fse_handles[1]._callback(nil, "op1", {})

    -- Debounce pending: cb not yet called
    assert.equals(0, called)

    -- Advance past debounce
    flush_timers()

    assert.equals(1, called)
  end)

  it("stop decrements ref; handle closed when refs reach 0", function()
    local root = "/repo/b"
    watcher.start(root, function() end)
    watcher.start(root, function() end)  -- second buffer, same root

    -- Only one handle ever created
    assert.equals(1, #fse_handles)
    local fse = fse_handles[1]
    assert.is_true(fse._started)

    watcher.stop(root)
    assert.is_true(fse._started)  -- refs still 1

    watcher.stop(root)
    assert.is_false(fse._started)  -- refs hit 0, handle closed
    assert.is_nil(watcher._watchers[root])
  end)

  it("multiple start calls on same root share one handle", function()
    local root = "/repo/c"
    watcher.start(root, function() end)
    watcher.start(root, function() end)
    watcher.start(root, function() end)

    assert.equals(1, #fse_handles)
    assert.equals(3, watcher._watchers[root].refs)
  end)

  it("rapid changes within debounce window fire cb only once", function()
    local root   = "/repo/d"
    local called = 0
    watcher.start(root, function() called = called + 1 end)

    local fse = fse_handles[1]

    -- Three rapid events — each resets the debounce timer
    fse._callback(nil, "op1", {})
    fse._callback(nil, "op2", {})
    fse._callback(nil, "op3", {})

    assert.equals(0, called)

    flush_timers()  -- only the last (still-running) timer fires

    assert.equals(1, called)
  end)
end)
