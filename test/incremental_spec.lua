local diff    = require("jj-signs.diff")
local signs   = require("jj-signs.signs")
local cache   = require("jj-signs.cache")
local jj_init = require("jj-signs.init")
local h       = require("test.helpers")
local eq      = h.eq

require("jj-signs.config").setup({})

--- @param t string type
--- @param s integer added.start
--- @param e integer vend
--- @return JJSigns.Hunk
local function hunk(t, s, e)
  return {
    type    = t,
    head    = "",
    added   = { start = s, count = e - s + 1, lines = {} },
    removed = { start = s, count = e - s + 1, lines = {} },
    vend    = e,
  }
end

describe("on_lines dirty_range tracking", function()
  local orig_attach, orig_get_root, orig_get_change_id, orig_schedule_refresh, orig_watcher_start
  local captured_on_lines
  local tmpfile, bufnr

  before_each(function()
    tmpfile = vim.fn.tempname() .. ".txt"
    local f = assert(io.open(tmpfile, "w"))
    f:write("a\nb\nc\n")
    f:close()
    bufnr = vim.fn.bufadd(tmpfile)
    vim.fn.bufload(bufnr)

    -- Capture the on_lines callback registered by attach().
    orig_attach = vim.api.nvim_buf_attach
    captured_on_lines = nil
    vim.api.nvim_buf_attach = function(_, _, opts)
      captured_on_lines = opts and opts.on_lines
      return true
    end

    -- Drive attach synchronously without subprocesses.
    orig_get_root = diff.get_root
    diff.get_root = function(_, cb) cb("/fake/root") end

    -- M.refresh runs inside attach; neuter its subprocess so no real spawn.
    orig_get_change_id = diff.get_change_id
    diff.get_change_id = function(_, _cb) end

    -- Avoid timers / real refresh during the test.
    local autocmds = require("jj-signs.autocmds")
    orig_schedule_refresh = autocmds.schedule_refresh
    autocmds.schedule_refresh = function() end

    orig_watcher_start = require("jj-signs.watcher").start
    require("jj-signs.watcher").start = function() end

    -- Stop M.refresh from doing work (no parent ids etc.).
    cache.clear(bufnr)
  end)

  after_each(function()
    vim.api.nvim_buf_attach = orig_attach
    diff.get_root = orig_get_root
    diff.get_change_id = orig_get_change_id
    require("jj-signs.autocmds").schedule_refresh = orig_schedule_refresh
    require("jj-signs.watcher").start = orig_watcher_start
    cache.clear(bufnr)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    os.remove(tmpfile)
  end)

  it("unions overlapping dirty ranges", function()
    jj_init.attach(bufnr)
    assert.is_not_nil(captured_on_lines)

    -- first edit: lines [5, 10)
    captured_on_lines(nil, bufnr, nil, 5, 5, 10, nil)
    local e = cache.get(bufnr)
    eq({ first = 5, last = 10 }, e.dirty_range)

    -- second edit overlapping & extending below: [3, 7)
    captured_on_lines(nil, bufnr, nil, 3, 5, 7, nil)
    eq({ first = 3, last = 10 }, e.dirty_range)
  end)

  it("returns true (detach) when entry gone", function()
    jj_init.attach(bufnr)
    cache.clear(bufnr)
    eq(true, captured_on_lines(nil, bufnr, nil, 0, 1, 2, nil))
  end)
end)

describe("diff.replace_hunks_in_range", function()
  it("keeps non-overlapping hunks, replaces overlapping ones", function()
    local existing = {
      hunk("add",    2,  3),   -- above range, kept
      hunk("change", 20, 22),  -- inside range, replaced
      hunk("add",    50, 51),  -- below range, kept
    }
    local partial = {
      hunk("change", 19, 24),
    }
    local result = diff.replace_hunks_in_range(existing, partial, 18, 25)
    eq(3, #result)
    -- sorted by added.start: 2, 19, 50
    eq(2,  result[1].added.start)
    eq(19, result[2].added.start)
    eq(50, result[3].added.start)
  end)

  it("handles empty existing and empty partial", function()
    eq({}, diff.replace_hunks_in_range({}, {}, 0, 10))
    eq(1, #diff.replace_hunks_in_range({}, { hunk("add", 1, 1) }, 0, 10))
    eq(1, #diff.replace_hunks_in_range({ hunk("add", 99, 99) }, {}, 0, 10))
  end)
end)

describe("narrow diff path in refresh()", function()
  local orig_schedule, orig_get_parent_ids, orig_diff_async, orig_place, orig_find_conflicts
  local placed
  local tmpfile, bufnr

  before_each(function()
    tmpfile = vim.fn.tempname() .. ".txt"
    local f = assert(io.open(tmpfile, "w"))
    f:write("l1\nl2\nl3\nl4\nl5\n")
    f:close()
    bufnr = vim.fn.bufadd(tmpfile)
    vim.fn.bufload(bufnr)
    -- Modify so refresh() takes the modified-buffer path.
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "l1", "l2", "CHANGED", "l4", "l5" })

    orig_schedule = vim.schedule
    vim.schedule = function(fn) fn() end

    orig_get_parent_ids = diff.get_parent_ids
    diff.get_parent_ids = function(_, cb) cb("pcid", "ppid") end

    -- Narrow diff returns a single-line change in the sliced region.
    orig_diff_async = diff.diff_async
    diff.diff_async = function(_, _, _, cb)
      cb("@@ -1,1 +1,1 @@\n-l3\n+CHANGED\n")
    end

    orig_find_conflicts = diff.find_conflicts
    diff.find_conflicts = function() return {} end

    orig_place = signs.place
    placed = nil
    signs.place = function(_, merged) placed = merged end
  end)

  after_each(function()
    vim.schedule = orig_schedule
    diff.get_parent_ids = orig_get_parent_ids
    diff.diff_async = orig_diff_async
    diff.find_conflicts = orig_find_conflicts
    signs.place = orig_place
    cache.clear(bufnr)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    os.remove(tmpfile)
  end)

  it("merges narrow result and clears dirty_range", function()
    cache.set(bufnr, {
      root             = "/fake",
      change_id        = "cid",
      mtime            = 0,
      hunks            = { hunk("add", 99, 99) },  -- far away, must survive
      dirty            = true,
      dirty_range      = { first = 2, last = 3 },
      base_text        = "l1\nl2\nl3\nl4\nl5\n",
      parent_change_id = "pcid",
      parent_commit_id = "ppid",
    })

    jj_init.refresh(bufnr)

    assert.is_not_nil(placed)
    local e = cache.get(bufnr)
    eq(nil, e.dirty_range)
    eq(false, e.dirty)
    -- far-away cached hunk preserved + the merged narrow hunk present
    local has_far = false
    for _, hk in ipairs(placed) do
      if hk.added.start == 99 then has_far = true end
    end
    eq(true, has_far)
  end)
end)
