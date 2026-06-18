require("jj-signs.config").setup({})
local signs = require("jj-signs.signs")
local h     = require("test.helpers")
local eq    = h.eq

local build = signs._build_hunk_index
local find  = signs._find_sign_at

local function mk(type, added_start, added_count, removed_count, vend_override)
  local vend = vend_override ~= nil and vend_override
    or (added_start + math.max(added_count - 1, 0))
  return {
    type    = type,
    head    = "",
    added   = { start = added_start, count = added_count,   lines = {} },
    removed = { start = added_start, count = removed_count, lines = {} },
    vend    = vend,
  }
end

describe("signs.build_hunk_index", function()
  it("maps add hunk to correct range", function()
    local idx = build({ mk("add", 3, 4, 0) })
    eq(1, #idx)
    eq(3, idx[1].start)
    eq(6, idx[1].vend)
    eq("add", idx[1].sign_type)
  end)

  it("maps change hunk to correct range", function()
    local idx = build({ mk("change", 5, 2, 2) })
    eq(1, #idx)
    eq(5, idx[1].start)
    eq(6, idx[1].vend)
    eq("change", idx[1].sign_type)
  end)

  it("detects topdelete (delete at start=0)", function()
    local h = mk("delete", 0, 0, 2, 0)
    local idx = build({ h })
    eq(1, #idx)
    eq("topdelete", idx[1].sign_type)
    eq(1, idx[1].start)
    eq(1, idx[1].vend)
  end)

  it("detects changedelete (removed > added)", function()
    local idx = build({ mk("change", 5, 1, 3) })
    eq("changedelete", idx[1].sign_type)
  end)

  it("does not mark change as changedelete when removed == added", function()
    local idx = build({ mk("change", 5, 2, 2) })
    eq("change", idx[1].sign_type)
  end)

  it("delete hunk vend equals start (single sign line)", function()
    local idx = build({ mk("delete", 8, 0, 2, 8) })
    eq(8, idx[1].start)
    eq(8, idx[1].vend)
    eq("delete", idx[1].sign_type)
  end)

  it("sorts output by start line", function()
    local hunks = {
      mk("add", 20, 1, 0),
      mk("add",  5, 1, 0),
      mk("add", 12, 1, 0),
    }
    local idx = build(hunks)
    eq(5,  idx[1].start)
    eq(12, idx[2].start)
    eq(20, idx[3].start)
  end)
end)

describe("signs.find_sign_at", function()
  local idx

  before_each(function()
    idx = build({
      mk("add",    1, 3, 0),   -- lines 1-3
      mk("change", 8, 2, 2),   -- lines 8-9
      mk("delete", 15, 0, 1, 15), -- line 15
    })
  end)

  it("finds entry at first line of range", function()
    local e = find(1, idx)
    assert.is_not_nil(e)
    eq("add", e.sign_type)
  end)

  it("finds entry at last line of range", function()
    local e = find(3, idx)
    assert.is_not_nil(e)
    eq("add", e.sign_type)
  end)

  it("finds middle entry", function()
    local e = find(8, idx)
    assert.is_not_nil(e)
    eq("change", e.sign_type)
  end)

  it("returns nil for line between hunks", function()
    assert.is_nil(find(5, idx))
  end)

  it("returns nil for line before all hunks", function()
    assert.is_nil(find(0, idx))
  end)

  it("returns nil for line after all hunks", function()
    assert.is_nil(find(20, idx))
  end)

  it("finds delete sign", function()
    local e = find(15, idx)
    assert.is_not_nil(e)
    eq("delete", e.sign_type)
  end)
end)
