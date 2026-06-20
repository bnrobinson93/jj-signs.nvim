local async = require("jj-signs.async")
local h = require("test.helpers")
local eq = h.eq

describe("async.throttle_async", function()
  local saved_schedule
  local queue

  before_each(function()
    -- Controllable scheduler: queue callbacks instead of running them, so a
    -- run stays "in-flight" while a burst of further calls arrives. drain()
    -- then lets the coroutine resumes (and any queued follow-up) play out.
    saved_schedule = vim.schedule
    queue = {}
    vim.schedule = function(f) table.insert(queue, f) end
  end)

  after_each(function()
    vim.schedule = saved_schedule
  end)

  local function drain()
    while #queue > 0 do
      local f = table.remove(queue, 1)
      f()
    end
  end

  -- An async fn that yields once (resume deferred onto the queue), modelling
  -- real async work that does not complete before the next call.
  local function make_async_fn(on_run)
    return function(bufnr)
      on_run(bufnr)
      local co = coroutine.running()
      vim.schedule(function() coroutine.resume(co) end)
      coroutine.yield()
    end
  end

  it("collapses 5 rapid same-key calls to at most 2 executions", function()
    local count = 0
    local throttled = async.throttle_async(
      make_async_fn(function() count = count + 1 end),
      function(bufnr) return bufnr end
    )

    for _ = 1, 5 do
      throttled(1)
    end

    -- First call in-flight, remaining 4 collapse into one pending follow-up.
    eq(1, count)
    drain()
    -- 1 running + 1 queued = 2 total executions.
    eq(2, count)
  end)

  it("clears pending after re-invoke finishes", function()
    local count = 0
    local throttled = async.throttle_async(
      make_async_fn(function() count = count + 1 end),
      function(bufnr) return bufnr end
    )

    throttled(7)
    throttled(7)  -- queues one follow-up
    drain()
    eq(2, count)

    -- pending was cleared by the follow-up; a fresh call runs immediately
    -- rather than being swallowed as still-pending.
    throttled(7)
    eq(3, count)
    drain()
    eq(3, count)  -- no extra phantom follow-up fired
  end)

  it("different keys do not block each other", function()
    local counts = {}
    local throttled = async.throttle_async(
      make_async_fn(function(bufnr) counts[bufnr] = (counts[bufnr] or 0) + 1 end),
      function(bufnr) return bufnr end
    )

    throttled(1)
    throttled(2)
    throttled(3)

    -- Each distinct key runs immediately despite the others being in-flight.
    eq(1, counts[1])
    eq(1, counts[2])
    eq(1, counts[3])
    drain()
    eq(1, counts[1])
    eq(1, counts[2])
    eq(1, counts[3])
  end)
end)
