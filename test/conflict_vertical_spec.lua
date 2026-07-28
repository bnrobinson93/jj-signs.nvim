-- Integration vertical for conflict handling. The unit specs cover scan_conflicts
-- / merge_hunks / parse_conflict_regions in isolation; this drives a conflicted
-- buffer through the REAL refresh pipeline (do_buf_diff → conflict.scan_conflicts
-- → conflict.merge_hunks → signs.place) and asserts the merge seam this refactor
-- moved into conflict.lua: conflict hunks win, and diff hunks overlapping a
-- conflict are dropped while non-overlapping ones survive.
local jjsigns = require("jj-signs")
local cache   = require("jj-signs.cache")
local diff    = require("jj-signs.diff")
local fake_jj = require("test.fake_jj")
local h       = require("test.helpers")
local eq      = h.eq

require("jj-signs.config").setup({})

describe("conflict integration vertical", function()
  local buf, orig_diff_async

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".txt")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "<<<<<<< Conflict 1 of 1",  -- 1  conflict block start
      "ours",                     -- 2
      "%%%%%%% Changes",          -- 3
      "theirs",                   -- 4
      ">>>>>>> Conflict 1 of 1",  -- 5  conflict block end
      "l6", "l7",                 -- 6,7
      "CHANGED8",                 -- 8  a normal change, clear of the conflict
      "l9", "l10",                -- 9,10
    })

    -- Diff produces one hunk overlapping the conflict (line 1) and one clear of it
    -- (line 8). The overlapping one must be dropped by the merge.
    orig_diff_async = diff.diff_async
    diff.diff_async = function(_, _, _, cb)
      cb("@@ -1,0 +1,1 @@\n+<<<<<<< Conflict 1 of 1\n@@ -8,1 +8,1 @@\n-old8\n+CHANGED8\n")
    end

    cache.set(buf, { root = "/fake", change_id = "old", hunks = {}, dirty = true, base_rev = "@-" })
    fake_jj.install({ change_id = "new" })
  end)

  after_each(function()
    diff.diff_async = orig_diff_async
    fake_jj.restore()
    cache.clear(buf)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("keeps the conflict hunk, drops the diff hunk overlapping it, keeps the clear one", function()
    jjsigns.refresh(buf)

    local e = cache.get(buf)
    assert.is_not_nil(e and e.hunks)
    eq(2, #e.hunks)  -- overlapping add dropped; conflict + clear change remain

    -- Sorted by added.start: conflict block first, then the line-8 change.
    eq("conflict", e.hunks[1].type)
    eq(1, e.hunks[1].added.start)
    eq(5, e.hunks[1].vend)
    eq("change", e.hunks[2].type)
    eq(8, e.hunks[2].added.start)
  end)

  it("places a conflict sign over the conflict block", function()
    jjsigns.refresh(buf)

    -- hunk_index is built regardless of the render path (extmark vs provider), so
    -- assert the sign classification there rather than poking extmarks.
    local e = cache.get(buf)
    local conflict_entry
    for _, entry in ipairs(e.hunk_index or {}) do
      if entry.sign_type == "conflict" then conflict_entry = entry end
    end
    assert.is_not_nil(conflict_entry, "expected a conflict sign spanning the block")
    eq(1, conflict_entry.start)
    eq(5, conflict_entry.vend)
  end)
end)
