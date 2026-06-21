--- Public API accessor tests: get_hunks returns a copy of the cached hunks,
--- detach_all clears every cache entry, is_attached reflects cache state.

local jjsigns = require("jj-signs")
local cache   = require("jj-signs.cache")
local signs   = require("jj-signs.signs")
local status  = require("jj-signs.status")
local h       = require("test.helpers")
local eq      = h.eq

describe("public API", function()
  local bufnr
  local orig_clear, orig_status_clear

  before_each(function()
    bufnr = vim.api.nvim_create_buf(false, true)
    -- Stub the rendering side effects detach pulls in, keep tests pure.
    orig_clear        = signs.clear
    orig_status_clear = status.clear
    signs.clear  = function() end
    status.clear = function() end
  end)

  after_each(function()
    signs.clear  = orig_clear
    status.clear = orig_status_clear
    for b in pairs(cache.all()) do cache.clear(b) end
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  describe("get_hunks", function()
    it("returns the cached hunks for a buffer", function()
      local hunks = { { added = { start = 1, count = 1 } } }
      cache.set(bufnr, { root = "/tmp/x", change_id = "", mtime = 0, hunks = hunks, dirty = false })
      eq(hunks, jjsigns.get_hunks(bufnr))
    end)

    it("returns a copy, not the live table", function()
      local hunks = { { added = { start = 1, count = 1 } } }
      cache.set(bufnr, { root = "/tmp/x", change_id = "", mtime = 0, hunks = hunks, dirty = false })
      local got = jjsigns.get_hunks(bufnr)
      assert.are_not.equal(hunks, got)
      got[1].added.start = 99
      eq(1, cache.get(bufnr).hunks[1].added.start)
    end)

    it("returns an empty table for an unattached buffer", function()
      eq({}, jjsigns.get_hunks(bufnr))
    end)
  end)

  describe("is_attached", function()
    it("is false before attach, true after a cache entry exists", function()
      assert.is_false(jjsigns.is_attached(bufnr))
      cache.set(bufnr, { root = "/tmp/x", change_id = "", mtime = 0, hunks = {}, dirty = false })
      assert.is_true(jjsigns.is_attached(bufnr))
    end)
  end)

  describe("detach_all", function()
    it("clears every cache entry", function()
      local b2 = vim.api.nvim_create_buf(false, true)
      cache.set(bufnr, { root = "/tmp/x", change_id = "", mtime = 0, hunks = {}, dirty = false })
      cache.set(b2,    { root = "/tmp/y", change_id = "", mtime = 0, hunks = {}, dirty = false })

      jjsigns.detach_all()

      eq({}, cache.all())
      vim.api.nvim_buf_delete(b2, { force = true })
    end)
  end)
end)
