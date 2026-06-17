--- Hunk utility tests.
--- Navigation and summary tests adapted from gitsigns.nvim (lewis6991/gitsigns.nvim) — MIT License

local M = require("jj-signs.hunks")
local h = require("test.helpers")
local eq = h.eq

--- Convenience: build a minimal Hunk
--- @param type JJSigns.HunkType
--- @param added_start integer
--- @param added_count integer
--- @param removed_start integer
--- @param removed_count integer
--- @return JJSigns.Hunk
local function mk_hunk(type, added_start, added_count, removed_start, removed_count)
  return {
    type    = type,
    head    = "",
    added   = { start = added_start,   count = added_count,   lines = {} },
    removed = { start = removed_start, count = removed_count, lines = {} },
    vend    = added_start + math.max(added_count - 1, 0),
  }
end

describe("hunks.find_hunk", function()
  it("finds hunk containing cursor line", function()
    local hunks = {
      mk_hunk("add", 5, 3, 0, 0),  -- lines 5-7
      mk_hunk("add", 15, 2, 0, 0), -- lines 15-16
    }
    local hunk, idx = M.find_hunk(6, hunks)
    assert.is_not_nil(hunk)
    eq(1, idx)
  end)

  it("returns nil when cursor not on any hunk", function()
    local hunks = { mk_hunk("add", 5, 2, 0, 0) }
    local hunk = M.find_hunk(10, hunks)
    assert.is_nil(hunk)
  end)

  it("finds topdelete hunk at line 1", function()
    local hunks = {
      { type = "delete", head = "", added = { start = 0, count = 0, lines = {} }, removed = { start = 1, count = 1, lines = {} }, vend = 0 },
    }
    local hunk, idx = M.find_hunk(1, hunks)
    assert.is_not_nil(hunk)
    eq(1, idx)
  end)
end)

describe("hunks.find_nearest_hunk", function()
  local hunks

  before_each(function()
    hunks = {
      mk_hunk("add",    3, 1, 0, 0),  -- line 3
      mk_hunk("change", 8, 2, 8, 2),  -- lines 8-9
      mk_hunk("delete", 15, 0, 15, 1),-- line 15
    }
  end)

  it("first returns 1", function()
    eq(1, M.find_nearest_hunk(1, hunks, "first"))
  end)

  it("last returns #hunks", function()
    eq(3, M.find_nearest_hunk(1, hunks, "last"))
  end)

  it("next from before first hunk returns 1", function()
    eq(1, M.find_nearest_hunk(1, hunks, "next"))
  end)

  it("next from line 3 returns hunk 2", function()
    eq(2, M.find_nearest_hunk(3, hunks, "next"))
  end)

  it("next from last hunk wraps to 1", function()
    eq(1, M.find_nearest_hunk(15, hunks, "next", true))
  end)

  it("prev from after last hunk returns last", function()
    eq(3, M.find_nearest_hunk(20, hunks, "prev"))
  end)

  it("prev from line 8 returns hunk 1", function()
    eq(1, M.find_nearest_hunk(8, hunks, "prev"))
  end)

  it("prev from first hunk wraps to last", function()
    eq(3, M.find_nearest_hunk(3, hunks, "prev", true))
  end)

  it("returns nil for empty hunks", function()
    assert.is_nil(M.find_nearest_hunk(5, {}, "next"))
  end)
end)

describe("hunks.get_summary", function()
  it("counts add, change, delete, conflict", function()
    local hunks = {
      mk_hunk("add",      1, 3, 0, 0),    -- +3 added
      mk_hunk("change",   5, 2, 5, 1),    -- 1 changed, 1 added
      mk_hunk("delete",  10, 0, 10, 2),   -- 2 deleted
      {                                    -- 1 conflict block
        type = "conflict",
        head = "",
        added   = { start = 15, count = 4, lines = {} },
        removed = { start = 15, count = 4, lines = {} },
        vend = 18,
      },
    }
    local s = M.get_summary(hunks)
    eq(3 + 1, s.added)     -- 3 from pure-add + 1 extra from change
    eq(1,     s.changed)   -- 1 delta from change
    eq(2,     s.deleted)   -- 2 from pure-delete
    eq(1,     s.conflicts) -- 1 conflict block
  end)

  it("returns zeros for empty hunks", function()
    local s = M.get_summary({})
    eq(0, s.added)
    eq(0, s.changed)
    eq(0, s.deleted)
    eq(0, s.conflicts)
  end)

  it("handles nil hunks", function()
    local s = M.get_summary(nil)
    eq(0, s.added)
  end)
end)
