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

  it("counts topdelete as deleted", function()
    local hunks = {
      { type = "topdelete", head = "",
        added   = { start = 0, count = 0, lines = {} },
        removed = { start = 1, count = 3, lines = {} },
        vend = 0 },
    }
    local s = M.get_summary(hunks)
    eq(3, s.deleted)
    eq(0, s.added)
    eq(0, s.changed)
  end)

  it("counts changedelete: changed + excess deleted", function()
    -- 1 added, 3 removed → 1 changed + 2 deleted
    local hunks = {
      { type = "changedelete", head = "",
        added   = { start = 5, count = 1, lines = {} },
        removed = { start = 5, count = 3, lines = {} },
        vend = 5 },
    }
    local s = M.get_summary(hunks)
    eq(1, s.changed)
    eq(2, s.deleted)
  end)
end)

describe("hunks.restore_hunk", function()
  local cache = require("jj-signs.cache")
  local api   = vim.api

  local function make_buf(lines, hunk, cursor)
    local tmp = vim.fn.tempname()
    local f   = io.open(tmp, "w")
    f:write(table.concat(lines, "\n") .. "\n")
    f:close()
    -- Use a normal (non-scratch) buffer so vim.cmd("update") can write
    local bufnr = api.nvim_create_buf(false, false)
    api.nvim_buf_set_name(bufnr, tmp)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    cache.set(bufnr, {
      root      = "/tmp",
      change_id = "test",
      mtime     = 0,
      hunks     = { hunk },
      dirty     = false,
    })
    api.nvim_set_current_buf(bufnr)
    api.nvim_win_set_cursor(0, { cursor, 0 })
    return bufnr
  end

  local function get_lines(bufnr)
    return api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end

  after_each(function()
    -- clean up any cache entries left over
    for _, bufnr in ipairs(api.nvim_list_bufs()) do
      cache.clear(bufnr)
    end
  end)

  it("change hunk: replaces added lines with removed lines", function()
    local hunk = {
      type    = "change",
      head    = "",
      added   = { start = 2, count = 1, lines = { "new line" } },
      removed = { start = 2, count = 1, lines = { "old line" } },
      vend    = 2,
    }
    local bufnr = make_buf({ "line1", "new line", "line3" }, hunk, 2)
    M.restore_hunk(bufnr)
    eq({ "line1", "old line", "line3" }, get_lines(bufnr))
  end)

  it("add hunk: removes the added lines (removed.lines = {})", function()
    local hunk = {
      type    = "add",
      head    = "",
      added   = { start = 2, count = 2, lines = { "extra1", "extra2" } },
      removed = { start = 2, count = 0, lines = {} },
      vend    = 3,
    }
    local bufnr = make_buf({ "line1", "extra1", "extra2", "line4" }, hunk, 2)
    M.restore_hunk(bufnr)
    eq({ "line1", "line4" }, get_lines(bufnr))
  end)

  it("delete hunk: re-inserts removed lines", function()
    local hunk = {
      type    = "delete",
      head    = "",
      added   = { start = 2, count = 0, lines = {} },
      removed = { start = 2, count = 2, lines = { "gone1", "gone2" } },
      vend    = 2,
    }
    local bufnr = make_buf({ "line1", "line4" }, hunk, 2)
    M.restore_hunk(bufnr)
    eq({ "line1", "gone1", "gone2", "line4" }, get_lines(bufnr))
  end)

  it("topdelete hunk: prepends removed lines at buffer start", function()
    local hunk = {
      type    = "topdelete",
      head    = "",
      added   = { start = 0, count = 0, lines = {} },
      removed = { start = 1, count = 1, lines = { "first" } },
      vend    = 0,
    }
    local bufnr = make_buf({ "second", "third" }, hunk, 1)
    M.restore_hunk(bufnr)
    eq({ "first", "second", "third" }, get_lines(bufnr))
  end)

  it("notifies and does nothing when cursor not on a hunk", function()
    local hunk = {
      type    = "change",
      head    = "",
      added   = { start = 5, count = 1, lines = { "new" } },
      removed = { start = 5, count = 1, lines = { "old" } },
      vend    = 5,
    }
    local bufnr = make_buf({ "a", "b", "c" }, hunk, 1)
    local original = get_lines(bufnr)
    M.restore_hunk(bufnr)  -- cursor on line 1, hunk at line 5
    eq(original, get_lines(bufnr))
  end)
end)

describe("hunks.reset_buffer", function()
  local cache = require("jj-signs.cache")
  local api   = vim.api

  local function make_buf(lines, base_text)
    local tmp = vim.fn.tempname()
    local f = io.open(tmp, "w"); f:write(table.concat(lines, "\n") .. "\n"); f:close()
    local bufnr = api.nvim_create_buf(false, false)
    api.nvim_buf_set_name(bufnr, tmp)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    cache.set(bufnr, { root = "/tmp", change_id = "t", mtime = 0, hunks = {}, dirty = false, base_text = base_text })
    api.nvim_set_current_buf(bufnr)
    return bufnr
  end

  after_each(function()
    for _, bufnr in ipairs(api.nvim_list_bufs()) do cache.clear(bufnr) end
  end)

  it("restores the whole buffer to base, dropping the trailing newline", function()
    local bufnr = make_buf({ "x", "CHANGED", "z", "extra" }, "x\ny\nz\n")
    M.reset_buffer(bufnr)
    eq({ "x", "y", "z" }, api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("does nothing (warns) when no base_text is cached", function()
    local bufnr = make_buf({ "a", "b" }, nil)
    M.reset_buffer(bufnr)
    eq({ "a", "b" }, api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)
end)

describe("hunks.preview_hunk_inline", function()
  local cache = require("jj-signs.cache")
  local api   = vim.api
  local preview_ns = api.nvim_create_namespace("jj-signs-preview-inline")

  after_each(function()
    for _, bufnr in ipairs(api.nvim_list_bufs()) do
      api.nvim_buf_clear_namespace(bufnr, preview_ns, 0, -1)
      cache.clear(bufnr)
    end
  end)

  it("places removed lines as virt_lines above a change hunk", function()
    local hunk = {
      type    = "change",
      head    = "",
      added   = { start = 2, count = 1, lines = { "new line" } },
      removed = { start = 2, count = 2, lines = { "old1", "old2" } },
      vend    = 2,
    }
    local bufnr = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line1", "new line", "line3" })
    cache.set(bufnr, { root = "/tmp", change_id = "t", mtime = 0, hunks = { hunk }, dirty = false })
    api.nvim_set_current_buf(bufnr)
    api.nvim_win_set_cursor(0, { 2, 0 })

    M.preview_hunk_inline()

    local marks = api.nvim_buf_get_extmarks(bufnr, preview_ns, 0, -1, { details = true })
    local virt_mark
    for _, m in ipairs(marks) do
      if m[4] and m[4].virt_lines then virt_mark = m end
    end
    assert.is_not_nil(virt_mark)
    eq(2, #virt_mark[4].virt_lines)              -- two removed lines
    eq("old1", virt_mark[4].virt_lines[1][1][1]) -- first removed line text
    eq(true, virt_mark[4].virt_lines_above)
  end)

  it("does nothing when cursor is not on a hunk", function()
    local hunk = {
      type    = "change",
      head    = "",
      added   = { start = 5, count = 1, lines = { "new" } },
      removed = { start = 5, count = 1, lines = { "old" } },
      vend    = 5,
    }
    local bufnr = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, { "a", "b", "c" })
    cache.set(bufnr, { root = "/tmp", change_id = "t", mtime = 0, hunks = { hunk }, dirty = false })
    api.nvim_set_current_buf(bufnr)
    api.nvim_win_set_cursor(0, { 1, 0 })

    M.preview_hunk_inline()

    local marks = api.nvim_buf_get_extmarks(bufnr, preview_ns, 0, -1, {})
    eq(0, #marks)
  end)
end)

describe("hunks.nav_hunk", function()
  local cache = require("jj-signs.cache")
  local api   = vim.api

  -- Buffer with 20 lines and hunks at lines 3, 8, 15.
  local function make_nav_buf(cursor)
    local lines = {}
    for i = 1, 20 do lines[i] = "line" .. i end
    local hunks = {
      mk_hunk("add",    3, 1, 0, 0),  -- line 3
      mk_hunk("change", 8, 2, 8, 2),  -- lines 8-9
      mk_hunk("add",   15, 1, 0, 0),  -- line 15
    }
    local bufnr = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    cache.set(bufnr, { root = "/tmp", change_id = "t", mtime = 0, hunks = hunks, dirty = false })
    api.nvim_set_current_buf(bufnr)
    api.nvim_win_set_cursor(0, { cursor, 0 })
    return bufnr
  end

  after_each(function()
    for _, bufnr in ipairs(api.nvim_list_bufs()) do
      cache.clear(bufnr)
    end
  end)

  it("respects wrap=false at the last-hunk boundary", function()
    make_nav_buf(15)  -- cursor on last hunk
    M.nav_hunk("next", { wrap = false, navigation_message = false })
    eq(15, api.nvim_win_get_cursor(0)[1])  -- no movement, no wrap to first
  end)

  it("wraps to first when wrap=true at the last-hunk boundary", function()
    make_nav_buf(15)
    M.nav_hunk("next", { wrap = true, navigation_message = false })
    eq(3, api.nvim_win_get_cursor(0)[1])
  end)

  it("count skips N hunks", function()
    make_nav_buf(1)  -- before first hunk
    M.nav_hunk("next", { count = 2, navigation_message = false })
    eq(8, api.nvim_win_get_cursor(0)[1])  -- hunk1 then hunk2
  end)
end)
