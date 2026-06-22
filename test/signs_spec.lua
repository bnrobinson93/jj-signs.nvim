require("jj-signs.config").setup({})
local api    = vim.api
local config = require("jj-signs.config")
local cache  = require("jj-signs.cache")
local signs  = require("jj-signs.signs")
local h      = require("test.helpers")
local eq     = h.eq

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

describe("signs.build_hunk_index with lnums (merged hunk)", function()
  it("skips context lines when lnums present", function()
    local hunk = {
      type    = "change",
      head    = "",
      added   = { start = 3, count = 2, lines = {}, lnums = { 3, 8 } },
      removed = { start = 3, count = 2, lines = {}, lnums = {} },
      vend    = 8,
    }
    local idx = build({ hunk })
    eq(1, #idx)
    -- Range still covers full merged span for binary-search bucketing
    eq(3, idx[1].start)
    eq(8, idx[1].vend)
    -- But context lines within the span are filtered
    assert.is_not_nil(find(3, idx))
    assert.is_not_nil(find(8, idx))
    assert.is_nil(find(4, idx))
    assert.is_nil(find(5, idx))
    assert.is_nil(find(6, idx))
    assert.is_nil(find(7, idx))
  end)

  it("does not filter when lnums absent (conflict hunks, legacy)", function()
    local hunk = {
      type    = "conflict",
      head    = "conflict",
      added   = { start = 2, count = 3, lines = {} },
      removed = { start = 2, count = 3, lines = {} },
      vend    = 4,
    }
    local idx = build({ hunk })
    assert.is_not_nil(find(2, idx))
    assert.is_not_nil(find(3, idx))
    assert.is_not_nil(find(4, idx))
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

-- Regression: a sign painted via the decoration provider must not linger after
-- the hunk disappears. on_line draws persistent sign marks from entry.hunk_index,
-- so M.clear() has to drop hunk_index too — otherwise the next redraw repaints
-- the very signs that were just cleared. See M.clear in signs.lua.
describe("signs.clear / place state reset", function()
  local function mk_buf(nlines)
    local buf = api.nvim_create_buf(false, true)
    local lines = {}
    for i = 1, (nlines or 5) do lines[i] = "line" .. i end
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    cache.set(buf, { root = "/tmp", change_id = "x", mtime = 0, hunks = {}, dirty = false })
    return buf
  end

  it("place() populates entry.hunk_index", function()
    local buf = mk_buf()
    signs.place(buf, { mk("add", 1, 2, 0) })
    local entry = cache.get(buf)
    assert.is_not_nil(entry.hunk_index)
    eq(1, #entry.hunk_index)
    api.nvim_buf_delete(buf, { force = true })
  end)

  it("clear() resets entry.hunk_index to nil", function()
    local buf = mk_buf()
    signs.place(buf, { mk("add", 1, 2, 0) })
    assert.is_not_nil(cache.get(buf).hunk_index)
    signs.clear(buf)
    assert.is_nil(cache.get(buf).hunk_index)
    api.nvim_buf_delete(buf, { force = true })
  end)

  it("place({}) after place(hunks) leaves no stale source state", function()
    local buf = mk_buf()
    signs.place(buf, { mk("add", 1, 2, 0) })
    signs.place(buf, {})
    -- empty hunk list -> empty index, nothing for on_line to draw
    eq(0, #cache.get(buf).hunk_index)
    api.nvim_buf_delete(buf, { force = true })
  end)

  -- Non-decoration-provider path must still place and clear real marks in ns.
  it("non-provider: place sets marks, place({}) removes them", function()
    local saved = config.config.use_decoration_provider
    config.config.use_decoration_provider = false
    local buf = mk_buf()

    signs.place(buf, { mk("add", 1, 2, 0) })
    local marks = api.nvim_buf_get_extmarks(buf, signs.ns, 0, -1, {})
    assert.is_true(#marks > 0)

    signs.place(buf, {})
    marks = api.nvim_buf_get_extmarks(buf, signs.ns, 0, -1, {})
    eq(0, #marks)

    config.config.use_decoration_provider = saved
    api.nvim_buf_delete(buf, { force = true })
  end)
end)
