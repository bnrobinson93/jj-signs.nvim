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

  it("flags needs_full_diff on a line-count-changing edit, not an in-place one", function()
    jj_init.attach(bufnr)
    local e = cache.get(bufnr)

    -- In-place edit (last_old == last_new): narrow path stays valid.
    captured_on_lines(nil, bufnr, nil, 2, 3, 3, nil)
    assert.is_not_true(e.needs_full_diff)

    -- Line deleted (last_new < last_old): below-hunks shift -> force full diff.
    captured_on_lines(nil, bufnr, nil, 2, 3, 2, nil)
    eq(true, e.needs_full_diff)
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

describe("CRLF / fileformat normalization", function()
  -- jj file show returns committed bytes verbatim (CRLF for a dos file), but
  -- nvim_buf_get_lines is always LF. Without folding the base to LF, every line
  -- of a non-unix file reads as changed.
  local orig_schedule, orig_get_change_id, orig_get_parent_ids, orig_diff_async,
        orig_place, orig_find_conflicts
  local placed, tmpfile, bufnr

  before_each(function()
    tmpfile = vim.fn.tempname() .. ".txt"
    local f = assert(io.open(tmpfile, "wb")); f:write("a\r\nb\r\nc\r\n"); f:close()
    bufnr = vim.fn.bufadd(tmpfile); vim.fn.bufload(bufnr)
    vim.bo[bufnr].fileformat = "dos"

    orig_schedule = vim.schedule; vim.schedule = function(fn) fn() end
    orig_get_change_id = diff.get_change_id; diff.get_change_id = function(_, cb) cb("cid") end
    orig_get_parent_ids = diff.get_parent_ids; diff.get_parent_ids = function(_, _, cb) cb("pcid", "ppid") end
    orig_diff_async = diff.diff_async
    diff.diff_async = function(base_text, buf_text, opts, cb)
      cb(vim.diff(base_text, buf_text, { result_type = "unified", ctxlen = opts.ctxlen or 0 }))
    end
    orig_find_conflicts = diff.find_conflicts; diff.find_conflicts = function() return {} end
    orig_place = signs.place; placed = nil; signs.place = function(_, m) placed = m end
  end)

  after_each(function()
    vim.schedule = orig_schedule
    diff.get_change_id = orig_get_change_id
    diff.get_parent_ids = orig_get_parent_ids
    diff.diff_async = orig_diff_async
    diff.find_conflicts = orig_find_conflicts
    signs.place = orig_place
    cache.clear(bufnr); pcall(vim.api.nvim_buf_delete, bufnr, { force = true }); os.remove(tmpfile)
  end)

  local function seed()
    cache.set(bufnr, {
      root = "/fake", change_id = "cid", mtime = 0, hunks = {}, dirty = true,
      base_text = "a\r\nb\r\nc\r\n",  -- CRLF base
      parent_change_id = "pcid", parent_commit_id = "ppid",
    })
  end

  it("reports no diff when a dos buffer matches its CRLF base", function()
    -- buffer (LF lines a,b,c) == base (a,b,c with CRLF) after normalization.
    seed()
    jj_init.refresh(bufnr)
    assert.is_not_nil(placed)
    eq(0, #placed)
  end)

  it("reports exactly one hunk for a single real change in a dos buffer", function()
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "B" })  -- b -> B
    seed()
    jj_init.refresh(bufnr)
    assert.is_not_nil(placed)
    eq(1, #placed)
    eq(2, placed[1].added.start)
  end)
end)

describe("narrow diff path in refresh()", function()
  local orig_schedule, orig_get_change_id, orig_get_parent_ids, orig_diff_async, orig_place, orig_find_conflicts
  local placed
  local tmpfile, bufnr

  before_each(function()
    tmpfile = vim.fn.tempname() .. ".txt"
    local f = assert(io.open(tmpfile, "w"))
    f:write("l1\nl2\nl3\nl4\nl5\n")
    f:close()
    bufnr = vim.fn.bufadd(tmpfile)
    vim.fn.bufload(bufnr)
    -- Modify so refresh() diffs the buffer against the cached base.
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "l1", "l2", "CHANGED", "l4", "l5" })

    orig_schedule = vim.schedule
    vim.schedule = function(fn) fn() end

    orig_get_change_id = diff.get_change_id
    diff.get_change_id = function(_, cb) cb("cid") end

    orig_get_parent_ids = diff.get_parent_ids
    diff.get_parent_ids = function(_, _, cb) cb("pcid", "ppid") end

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
    diff.get_change_id = orig_get_change_id
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

describe("narrow diff path: deletion alignment", function()
  -- Regression: deleting a line made the narrow path slice base & buffer by the
  -- same line numbers. Below the deletion the two drift apart by the line delta,
  -- so the equal-numbered base slice pulled in a shifted line — the deletion
  -- rendered as a spurious "-x/+y" change marker instead of a clean delete sign.
  local orig_schedule, orig_get_change_id, orig_get_parent_ids, orig_diff_async,
        orig_place, orig_find_conflicts
  local placed, tmpfile, bufnr

  before_each(function()
    tmpfile = vim.fn.tempname() .. ".txt"
    local f = assert(io.open(tmpfile, "w"))
    f:write("l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n")
    f:close()
    bufnr = vim.fn.bufadd(tmpfile)
    vim.fn.bufload(bufnr)
    -- Delete line 5 (l5).
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "l1", "l2", "l3", "l4", "l6", "l7", "l8" })

    orig_schedule = vim.schedule
    vim.schedule = function(fn) fn() end

    orig_get_change_id = diff.get_change_id
    diff.get_change_id = function(_, cb) cb("cid") end
    orig_get_parent_ids = diff.get_parent_ids
    diff.get_parent_ids = function(_, _, cb) cb("pcid", "ppid") end

    -- Real vim.diff on exactly the (base_narrow, buf_narrow) the path computed,
    -- so the slice alignment is what is under test.
    orig_diff_async = diff.diff_async
    diff.diff_async = function(base_narrow, buf_narrow, opts, cb)
      cb(vim.diff(base_narrow, buf_narrow, { result_type = "unified", ctxlen = opts.ctxlen or 3 }))
    end

    orig_find_conflicts = diff.find_conflicts
    diff.find_conflicts = function() return {} end

    orig_place = signs.place
    placed = nil
    signs.place = function(_, merged) placed = merged end
  end)

  after_each(function()
    vim.schedule = orig_schedule
    diff.get_change_id = orig_get_change_id
    diff.get_parent_ids = orig_get_parent_ids
    diff.diff_async = orig_diff_async
    diff.find_conflicts = orig_find_conflicts
    signs.place = orig_place
    cache.clear(bufnr)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    os.remove(tmpfile)
  end)

  it("produces a single clean delete hunk anchored above the gap", function()
    cache.set(bufnr, {
      root             = "/fake",
      change_id        = "cid",
      mtime            = 0,
      hunks            = {},
      dirty            = true,
      dirty_range      = { first = 4, last = 4 },  -- 0-indexed: deleted line 5
      base_text        = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n",
      parent_change_id = "pcid",
      parent_commit_id = "ppid",
    })

    jj_init.refresh(bufnr)

    assert.is_not_nil(placed)
    eq(1, #placed)
    eq("delete", placed[1].type)
    eq(4, placed[1].added.start)  -- anchored on the line above the deletion
    eq(4, placed[1].vend)
  end)
end)

describe("needs_full_diff: change below a deletion", function()
  -- Regression: a line-count-changing edit left cached below-hunks at stale
  -- positions when the narrow path ran. needs_full_diff forces a whole-buffer
  -- re-diff so a change below a deletion lands at its shifted (correct) line.
  local orig_schedule, orig_get_change_id, orig_get_parent_ids, orig_diff_async,
        orig_place, orig_find_conflicts
  local placed, captured_base, tmpfile, bufnr

  before_each(function()
    tmpfile = vim.fn.tempname() .. ".txt"
    local f = assert(io.open(tmpfile, "w"))
    local b = {} for i = 1, 16 do b[i] = "L" .. i end
    f:write(table.concat(b, "\n") .. "\n")
    f:close()
    bufnr = vim.fn.bufadd(tmpfile)
    vim.fn.bufload(bufnr)
    -- Deleted L3, changed L12 -> X12.
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "L1", "L2", "L4", "L5", "L6", "L7", "L8", "L9", "L10", "L11", "X12", "L13", "L14", "L15", "L16",
    })

    orig_schedule = vim.schedule
    vim.schedule = function(fn) fn() end
    orig_get_change_id = diff.get_change_id
    diff.get_change_id = function(_, cb) cb("cid") end
    orig_get_parent_ids = diff.get_parent_ids
    diff.get_parent_ids = function(_, _, cb) cb("pcid", "ppid") end

    orig_diff_async = diff.diff_async
    diff.diff_async = function(base_text, buf_text, opts, cb)
      captured_base = base_text
      cb(vim.diff(base_text, buf_text, { result_type = "unified", ctxlen = opts.ctxlen or 3 }))
    end
    orig_find_conflicts = diff.find_conflicts
    diff.find_conflicts = function() return {} end
    orig_place = signs.place
    placed = nil
    signs.place = function(_, merged) placed = merged end
  end)

  after_each(function()
    vim.schedule = orig_schedule
    diff.get_change_id = orig_get_change_id
    diff.get_parent_ids = orig_get_parent_ids
    diff.diff_async = orig_diff_async
    diff.find_conflicts = orig_find_conflicts
    signs.place = orig_place
    cache.clear(bufnr)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    os.remove(tmpfile)
  end)

  it("re-diffs the whole buffer, ignoring dirty_range and stale below-hunks", function()
    local b = {} for i = 1, 16 do b[i] = "L" .. i end
    cache.set(bufnr, {
      root             = "/fake",
      change_id        = "cid",
      mtime            = 0,
      hunks            = { hunk("change", 12, 12) },  -- stale pre-deletion position
      dirty            = true,
      dirty_range      = { first = 2, last = 2 },     -- must be ignored
      needs_full_diff  = true,
      base_text        = table.concat(b, "\n") .. "\n",
      parent_change_id = "pcid",
      parent_commit_id = "ppid",
    })

    jj_init.refresh(bufnr)

    -- Full base text was diffed (not a narrow slice).
    eq(table.concat(b, "\n") .. "\n", captured_base)
    assert.is_not_nil(placed)
    eq(2, #placed)
    eq("delete", placed[1].type)
    eq(2, placed[1].added.start)
    eq("change", placed[2].type)
    eq(11, placed[2].added.start)  -- shifted up by the deletion (was 12)

    local e = cache.get(bufnr)
    eq(false, e.needs_full_diff)
    eq(nil, e.dirty_range)
  end)
end)

describe("refresh() change_id subprocess skip (P11e)", function()
  local tmpfile, bufnr, orig_get_change_id, calls

  before_each(function()
    tmpfile = vim.fn.tempname() .. ".txt"
    local f = assert(io.open(tmpfile, "w")); f:write("a\nb\n"); f:close()
    bufnr = vim.fn.bufadd(tmpfile); vim.fn.bufload(bufnr)

    calls = 0
    orig_get_change_id = diff.get_change_id
    diff.get_change_id = function(_, _cb) calls = calls + 1 end
  end)

  local watcher = require("jj-signs.watcher")

  after_each(function()
    diff.get_change_id = orig_get_change_id
    watcher._op_gen["/fake"] = nil
    watcher._op_cid["/fake"] = nil
    cache.clear(bufnr)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    os.remove(tmpfile)
  end)

  local function seed()
    cache.set(bufnr, {
      root = "/fake", change_id = "cid", base_text = "a\nb\n",
      mtime = 0, hunks = {}, dirty = false, base_rev = "@-",
    })
  end

  it("reuses cached change_id (no jj log) when the op generation is unchanged", function()
    seed()
    watcher._op_gen["/fake"] = 1
    watcher._op_cid["/fake"] = { gen = 1, change_id = "cid" }
    jj_init.refresh(bufnr)
    eq(0, calls)
  end)

  it("runs jj log when the watcher bumped the op generation", function()
    seed()
    watcher._op_gen["/fake"] = 2          -- watcher advanced the generation
    watcher._op_cid["/fake"] = { gen = 1, change_id = "cid" }  -- read at an older gen
    jj_init.refresh(bufnr)
    eq(1, calls)
  end)
end)

describe("refresh() conflict scan guard (P11c)", function()
  local tmpfile, bufnr
  local orig_schedule, orig_diff_async, orig_find_conflicts, orig_place
  local fc_calls
  local watcher = require("jj-signs.watcher")

  before_each(function()
    tmpfile = vim.fn.tempname() .. ".txt"
    local f = assert(io.open(tmpfile, "w")); f:write("a\nb\nc\n"); f:close()
    bufnr = vim.fn.bufadd(tmpfile); vim.fn.bufload(bufnr)

    orig_schedule = vim.schedule
    vim.schedule = function(fn) fn() end

    -- Stub the off-thread diff so the pipeline runs synchronously and reaches the
    -- conflict scan inside do_buf_diff.
    orig_diff_async = diff.diff_async
    diff.diff_async = function(_, _, _, cb) cb("") end

    fc_calls = 0
    orig_find_conflicts = diff.find_conflicts
    diff.find_conflicts = function() fc_calls = fc_calls + 1; return {} end

    orig_place = signs.place
    signs.place = function() end
  end)

  after_each(function()
    vim.schedule = orig_schedule
    diff.diff_async = orig_diff_async
    diff.find_conflicts = orig_find_conflicts
    signs.place = orig_place
    watcher._op_gen["/fake"] = nil
    watcher._op_cid["/fake"] = nil
    cache.clear(bufnr)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    os.remove(tmpfile)
  end)

  -- Seed so refresh runs no subprocess: cached change_id at the current op
  -- generation, base text present, parent ids resolved at that generation. dirty
  -- forces the diff (and thus the conflict scan) to run.
  local function seed()
    watcher._op_gen["/fake"] = 1
    watcher._op_cid["/fake"] = { gen = 1, change_id = "cid" }
    cache.set(bufnr, {
      root = "/fake", change_id = "cid", base_text = "a\nb\nc\n",
      mtime = 0, hunks = {}, dirty = true, base_rev = "@-",
      parent_change_id = "pcid", parent_commit_id = "ppid", parent_gen = 1,
    })
  end

  it("skips find_conflicts when the buffer has no conflict marker", function()
    seed()
    jj_init.refresh(bufnr)
    eq(0, fc_calls)
  end)

  it("scans conflicts when a marker is present", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "x", "<<<<<<< Conflict 1 of 1", ">>>>>>> Conflict 1 of 1 ends",
    })
    seed()
    jj_init.refresh(bufnr)
    eq(1, fc_calls)
  end)
end)
