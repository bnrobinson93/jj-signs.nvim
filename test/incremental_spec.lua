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

describe("diff in refresh()", function()
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

    -- Whole-buffer diff returns the single-line change.
    orig_diff_async = diff.diff_async
    diff.diff_async = function(_, _, _, cb)
      cb("@@ -3,1 +3,1 @@\n-l3\n+CHANGED\n")
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

  it("places the diffed hunk and clears dirty_range", function()
    cache.set(bufnr, {
      root             = "/fake",
      change_id        = "cid",
      mtime            = 0,
      hunks            = { hunk("add", 99, 99) },  -- stale, replaced by the re-diff
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
    -- The whole-buffer re-diff replaces the cached hunks: only the change@3
    -- remains; the stale far-away hunk is gone.
    eq(1, #placed)
    eq("change", placed[1].type)
    eq(3, placed[1].added.start)
  end)
end)

describe("deletion alignment", function()
  -- Regression: a deletion must render as a clean delete sign anchored above the
  -- gap, not a spurious "-x/+y" change marker.
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

    -- Real vim.diff on the (base, buffer) the path passes, so hunk anchoring is
    -- what is under test.
    orig_diff_async = diff.diff_async
    diff.diff_async = function(base, buf, opts, cb)
      cb(vim.diff(base, buf, { result_type = "unified", ctxlen = opts.ctxlen or 3 }))
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

describe("whole-buffer re-diff: change below a deletion", function()
  -- Regression: a stale below-hunk must not survive a refresh. refresh() always
  -- re-diffs the whole buffer, so a change below a deletion lands at its shifted
  -- (correct) line and the cached pre-edit position is discarded.
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

describe("base swap re-diffs against the new base (stale-hunk regression)", function()
  -- Regression: when an op lands and the comparison base changes, the cached
  -- hunks are relative to the OLD base. The refresh must re-diff the whole buffer
  -- against the new base so a line re-classifies correctly (e.g. a `change`/blue
  -- that should now be an `add`/green), rather than keeping its old sign until
  -- undo or reopen.
  local orig_schedule, orig_get_change_id, orig_get_parent_ids, orig_fetch_base,
        orig_diff_async, orig_find_conflicts, orig_place
  local placed, tmpfile, bufnr
  local watcher = require("jj-signs.watcher")
  local base_cache = require("jj-signs.base_cache")

  -- Buffer holds change B's content: "Xmod" sits at line 3, far above the pending
  -- dirty range. Against base A (which has "X" there) line 3 is a `change`;
  -- against the new base (root, no such line) it is an `add`.
  local buf_lines = {
    "l1", "l2", "Xmod", "l3", "l4", "l5", "l6", "l7", "l8", "l9", "l10", "l11", "l12",
  }
  local base_A    = "l1\nl2\nX\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\n"
  local base_root = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\n"

  before_each(function()
    tmpfile = vim.fn.tempname() .. ".txt"
    local f = assert(io.open(tmpfile, "w")); f:write(base_root); f:close()
    bufnr = vim.fn.bufadd(tmpfile); vim.fn.bufload(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, buf_lines)

    orig_schedule = vim.schedule
    vim.schedule = function(fn) fn() end

    orig_get_change_id = diff.get_change_id
    diff.get_change_id = function(_, cb) cb("cidA") end

    -- New parent ids (the swap): differ from the cached A ids, so refresh drops
    -- the cached base and re-fetches.
    orig_get_parent_ids = diff.get_parent_ids
    diff.get_parent_ids = function(_, _, cb) cb("pcidRoot", "ppidRoot") end

    orig_fetch_base = diff.fetch_base
    diff.fetch_base = function(_, _, _, cb) cb(base_root) end

    orig_diff_async = diff.diff_async
    diff.diff_async = function(a, b, opts, cb)
      cb(vim.diff(a, b, { result_type = "unified", ctxlen = opts.ctxlen or 0 }))
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
    diff.fetch_base = orig_fetch_base
    diff.diff_async = orig_diff_async
    diff.find_conflicts = orig_find_conflicts
    signs.place = orig_place
    watcher._op_gen["/fake"] = nil
    watcher._op_cid["/fake"] = nil
    base_cache._clear()
    cache.clear(bufnr)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    os.remove(tmpfile)
  end)

  it("re-diffs the whole buffer against the new base instead of keeping stale hunks", function()
    -- Op generation advanced past the one the parent ids were resolved at, so
    -- refresh re-resolves them and observes the base swap.
    watcher._op_gen["/fake"] = 2
    watcher._op_cid["/fake"] = { gen = 2, change_id = "cidA" }
    cache.set(bufnr, {
      root             = "/fake",
      change_id        = "cidA",
      mtime            = 0,
      -- Stale: a `change` at line 3, computed against base A.
      hunks            = { hunk("change", 3, 3) },
      dirty            = true,
      dirty_range      = { first = 9, last = 9 },  -- pending, far from line 3
      base_text        = base_A,
      base_rev         = "@-",
      parent_change_id = "pcidA",
      parent_commit_id = "ppidA",
      parent_gen       = 1,
    })

    jj_init.refresh(bufnr)

    assert.is_not_nil(placed)
    -- Line 3 must re-classify as an add against the new (root) base; the stale
    -- `change` must not survive.
    local at3
    for _, hk in ipairs(placed) do
      for _, l in ipairs(hk.added.lnums or {}) do
        if l == 3 then at3 = hk.type end
      end
      if hk.added.start == 3 then at3 = at3 or hk.type end
    end
    eq("add", at3)
    for _, hk in ipairs(placed) do
      assert.are_not.equal("change", hk.type)
    end
  end)
end)

describe("in-place edit inside an added block stays add", function()
  -- User-visible regression guard: editing a line that is part of a block of
  -- added lines must keep the whole block classified as `add` (green), never flip
  -- it to `change` (blue). (An earlier narrow per-keystroke diff path mis-handled
  -- this; it has since been retired in favour of a whole-buffer re-diff.)
  local orig_schedule, orig_get_change_id, orig_get_parent_ids, orig_diff_async,
        orig_find_conflicts, orig_place
  local placed, tmpfile, bufnr
  local watcher = require("jj-signs.watcher")

  before_each(function()
    tmpfile = vim.fn.tempname() .. ".txt"
    -- base has 3 "asdf" lines; buffer adds 4 more below them.
    local f = assert(io.open(tmpfile, "w")); f:write("asdf\nasdf\nasdf\n"); f:close()
    bufnr = vim.fn.bufadd(tmpfile); vim.fn.bufload(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "asdf", "asdf", "asdf", "asdfj", "asdf", "asdfasdf", "asdfX",
    })

    orig_schedule = vim.schedule
    vim.schedule = function(fn) fn() end
    orig_get_change_id = diff.get_change_id
    diff.get_change_id = function(_, cb) cb("cid") end
    orig_get_parent_ids = diff.get_parent_ids
    diff.get_parent_ids = function(_, _, cb) cb("pcid", "ppid") end
    orig_diff_async = diff.diff_async
    diff.diff_async = function(a, b, opts, cb)
      cb(vim.diff(a, b, { result_type = "unified", ctxlen = opts.ctxlen or 0 }))
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
    watcher._op_gen["/fake"] = nil
    watcher._op_cid["/fake"] = nil
    cache.clear(bufnr)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    os.remove(tmpfile)
  end)

  it("keeps an in-place edit inside an added block classified as add, not change", function()
    watcher._op_gen["/fake"] = 1
    watcher._op_cid["/fake"] = { gen = 1, change_id = "cid" }
    cache.set(bufnr, {
      root             = "/fake",
      change_id        = "cid",
      mtime            = 0,
      -- The 4 added lines below the base, already diffed as one add block.
      hunks            = { hunk("add", 4, 7) },
      dirty            = true,
      dirty_range      = { first = 6, last = 7 },  -- in-place edit on line 7
      base_text        = "asdf\nasdf\nasdf\n",
      base_rev         = "@-",
      parent_change_id = "pcid",
      parent_commit_id = "ppid",
      parent_gen       = 1,
    })

    jj_init.refresh(bufnr)

    assert.is_not_nil(placed)
    for _, hk in ipairs(placed) do
      assert.are_not.equal("change", hk.type)
      eq(0, hk.removed.count)
    end
    -- The edited line stays part of an add.
    local covered = false
    for _, hk in ipairs(placed) do
      if hk.type == "add" and hk.added.start <= 7 and hk.vend >= 7 then covered = true end
    end
    assert.is_true(covered)
  end)
end)
