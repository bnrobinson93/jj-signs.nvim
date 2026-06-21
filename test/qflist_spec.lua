--- Quickfix / location list tests: items built from cached hunks across buffers.

local M     = require("jj-signs.qflist")
local cache = require("jj-signs.cache")
local h     = require("test.helpers")
local eq    = h.eq
local api   = vim.api

--- Build a minimal cache-shaped Hunk.
--- @param type JJSigns.HunkType
--- @param added_start integer
--- @param head string?
--- @return JJSigns.Hunk
local function mk_hunk(type, added_start, head)
  return {
    type    = type,
    head    = head or "",
    added   = { start = added_start, count = 1, lines = {} },
    removed = { start = added_start, count = 0, lines = {} },
    vend    = added_start,
  }
end

--- @param bufnr integer
--- @param hunks JJSigns.Hunk[]
local function attach(bufnr, hunks)
  cache.set(bufnr, {
    root      = "/tmp",
    change_id = "test",
    mtime     = 0,
    dirty     = false,
    hunks     = hunks,
  })
end

describe("qflist", function()
  local buf1, buf2

  before_each(function()
    buf1 = api.nvim_create_buf(false, true)
    buf2 = api.nvim_create_buf(false, true)
    attach(buf1, {
      mk_hunk("add",    5,  "@@ -0,0 +5,1 @@"),
      mk_hunk("change", 12, "@@ -12,1 +12,1 @@"),
    })
    attach(buf2, {
      mk_hunk("delete", 0, ""),  -- empty head, lnum should clamp to 1
    })
  end)

  after_each(function()
    for _, b in ipairs(api.nvim_list_bufs()) do
      cache.clear(b)
    end
  end)

  describe("build_items", function()
    it("collects hunks across all attached buffers", function()
      local items = M.build_items("attached")
      eq(3, #items)
    end)

    it("nil target == attached (all buffers)", function()
      eq(3, #M.build_items(nil))
    end)

    it("uses hunk.added.start as lnum", function()
      local items = M.build_items(buf1)
      eq(2, #items)
      eq(5,  items[1].lnum)
      eq(12, items[2].lnum)
    end)

    it("clamps delete/topdelete lnum to 1", function()
      local items = M.build_items(buf2)
      eq(1, #items)
      eq(1, items[1].lnum)
    end)

    it("text combines type and head", function()
      local items = M.build_items(buf1)
      eq("add @@ -0,0 +5,1 @@",     items[1].text)
      eq("change @@ -12,1 +12,1 @@", items[2].text)
    end)

    it("text falls back to type when head empty", function()
      local items = M.build_items(buf2)
      eq("delete", items[1].text)
    end)

    it("sets bufnr on each item", function()
      local items = M.build_items(buf1)
      eq(buf1, items[1].bufnr)
      eq(buf1, items[2].bufnr)
    end)

    it("a bufnr target limits items to that buffer", function()
      eq(1, #M.build_items(buf2))
    end)

    it("string bufnr target (from CLI) coerced to number", function()
      eq(2, #M.build_items(tostring(buf1)))
    end)

    it("skips buffers with no cached hunks", function()
      local empty = api.nvim_create_buf(false, true)
      attach(empty, {})
      eq(0, #M.build_items(empty))
    end)
  end)

  describe("setqflist", function()
    it("populates the quickfix list from cache", function()
      M.setqflist("attached")
      local qf = vim.fn.getqflist()
      eq(3, #qf)
    end)

    it("preserves lnum and text in the quickfix list", function()
      M.setqflist(buf1)
      local qf = vim.fn.getqflist()
      eq(2,  #qf)
      eq(5,  qf[1].lnum)
      eq("add @@ -0,0 +5,1 @@", qf[1].text)
    end)
  end)

  describe("setloclist", function()
    it("populates the current window's location list", function()
      api.nvim_set_current_buf(buf1)
      M.setloclist(buf1)
      local loc = vim.fn.getloclist(0)
      eq(2, #loc)
    end)
  end)
end)
