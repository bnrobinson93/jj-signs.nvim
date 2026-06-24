-- Regression tests for refresh performance/caching behaviour:
--  1. The modified-buffer path must not re-spawn `jj log @-` (get_parent_ids) on
--     every refresh while the operation is unchanged and base content is cached.
--  2. Refreshes driven through the throttle (schedule_refresh) must serialize:
--     a burst collapses instead of fanning out overlapping diff subprocesses.
local fixtures = require("test.fixtures")
local helpers  = require("test.async_helpers")
local jj_init  = require("jj-signs.init")
local autocmds = require("jj-signs.autocmds")
local diff_mod = require("jj-signs.diff")
local cache    = require("jj-signs.cache")

describe("refresh caching + throttling", function()
  if vim.fn.executable("jj") == 0 then
    pending("jj binary not found — skipping refresh throttle tests")
    return
  end

  local root, bufnr, filepath

  before_each(function()
    jj_init.setup({})
    root = fixtures.make_jj_repo()
    filepath = root .. "/test.lua"
    bufnr = vim.fn.bufadd(filepath)
    vim.fn.bufload(bufnr)
    jj_init.attach(bufnr)
    helpers.wait_for_refresh(bufnr, 3000)
  end)

  after_each(function()
    pcall(jj_init.detach, bufnr)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    fixtures.cleanup(root)
  end)

  it("does not re-resolve parent ids when op is unchanged and base is cached", function()
    -- First modified refresh: resolves parent ids + caches base content.
    vim.api.nvim_buf_set_lines(bufnr, 1, 1, false, { "local first_edit = true" })
    jj_init.refresh(bufnr)
    local seeded = helpers.wait_until(function()
      local e = cache.get(bufnr)
      return e ~= nil and e.base_text ~= nil and e.dirty == false
    end, 3000)
    assert.is_true(seeded, "expected base_text cached after first modified refresh")

    -- Spy on get_parent_ids and diff_async for the SECOND refresh only.
    local orig_parent = diff_mod.get_parent_ids
    local orig_diff   = diff_mod.diff_async
    local parent_calls, diff_calls = 0, 0
    diff_mod.get_parent_ids = function(...) parent_calls = parent_calls + 1; return orig_parent(...) end
    diff_mod.diff_async     = function(...) diff_calls   = diff_calls   + 1; return orig_diff(...) end

    -- Second modified refresh, same operation (no jj op ran between).
    vim.api.nvim_buf_set_lines(bufnr, 2, 2, false, { "local second_edit = true" })
    jj_init.refresh(bufnr)
    helpers.wait_until(function() return diff_calls > 0 end, 2000)
    -- let any stray subprocess settle
    vim.wait(150, function() return false end)

    diff_mod.get_parent_ids = orig_parent
    diff_mod.diff_async     = orig_diff

    assert.is_true(diff_calls >= 1, "expected the diff to actually run on the second refresh")
    assert.are.equal(0, parent_calls,
      "get_parent_ids should be skipped when op unchanged + base cached, got " .. parent_calls)
  end)

  it("serializes a burst of scheduled refreshes (no overlapping diffs)", function()
    -- Put the buffer in the current window so schedule_refresh does not defer.
    vim.api.nvim_set_current_buf(bufnr)

    -- Seed the diff pipeline once so base text is cached; the burst below then
    -- exercises only the diff step.
    jj_init.refresh(bufnr)
    helpers.wait_until(function()
      local e = cache.get(bufnr)
      return e ~= nil and e.base_text ~= nil
    end, 3000)

    -- vim.diff is the diff mechanism for both saved and unsaved buffers now.
    local orig_diff = diff_mod.diff_async
    local inflight, max_inflight, total = 0, 0, 0
    diff_mod.diff_async = function(a, b, opts, cb)
      total = total + 1
      inflight = inflight + 1
      if inflight > max_inflight then max_inflight = inflight end
      return orig_diff(a, b, opts, function(out)
        inflight = inflight - 1
        cb(out)
      end)
    end

    -- Fire a tight burst. Each schedule_refresh marks the buffer dirty first so
    -- the refresh is forced to diff rather than short-circuiting.
    for _ = 1, 6 do
      cache.invalidate(bufnr)
      autocmds.schedule_refresh(bufnr)
    end

    -- Let the burst drain.
    vim.wait(2000, function() return inflight == 0 and total > 0 end)
    vim.wait(150, function() return false end)

    diff_mod.diff_async = orig_diff

    assert.is_true(total > 0, "expected at least one diff to run")
    assert.are.equal(1, max_inflight,
      "refreshes must not run overlapping diffs; max concurrent was " .. max_inflight)
    assert.is_true(total <= 2,
      "a 6-call burst should collapse to at most 2 diffs, got " .. total)
  end)
end)
