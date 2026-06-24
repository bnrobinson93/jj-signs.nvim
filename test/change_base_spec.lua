local jj_init   = require("jj-signs.init")
local cache     = require("jj-signs.cache")
local diff      = require("jj-signs.diff")
local base_cache = require("jj-signs.base_cache")
local signs     = require("jj-signs.signs")
local h         = require("test.helpers")
local eq        = h.eq

require("jj-signs.config").setup({})

describe("change_base / reset_base", function()
  local orig = {}
  local tmpfile, bufnr
  local fetched_revs, resolved_revs

  before_each(function()
    tmpfile = vim.fn.tempname() .. ".txt"
    local f = assert(io.open(tmpfile, "w"))
    f:write("original\n")
    f:close()
    bufnr = vim.fn.bufadd(tmpfile)
    vim.fn.bufload(bufnr)
    -- Modify so refresh() takes the modified-buffer (base-fetch) path.
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "original", "MODIFIED" })

    fetched_revs  = {}
    resolved_revs = {}

    orig.schedule = vim.schedule
    vim.schedule = function(fn) fn() end

    orig.get_change_id = diff.get_change_id
    diff.get_change_id = function(_, cb) cb("cid") end

    -- Distinct parent ids per rev so base_text invalidation always triggers a
    -- fresh fetch_base for that rev.
    orig.get_parent_ids = diff.get_parent_ids
    diff.get_parent_ids = function(_, rev, cb)
      resolved_revs[#resolved_revs + 1] = rev
      cb("pcid-" .. rev, "ppid-" .. rev)
    end

    orig.fetch_base = diff.fetch_base
    diff.fetch_base = function(_, _, rev, cb)
      fetched_revs[#fetched_revs + 1] = rev
      cb("base of " .. rev .. "\n")
    end

    orig.diff_async = diff.diff_async
    diff.diff_async = function(_, _, _, cb) cb("") end

    orig.find_conflicts = diff.find_conflicts
    diff.find_conflicts = function() return {} end

    orig.place = signs.place
    signs.place = function() end

    base_cache._clear()

    cache.set(bufnr, {
      root        = "/fake",
      change_id   = "cid",
      mtime       = 0,
      hunks       = {},
      dirty       = true,
      base_rev    = "@-",
    })
  end)

  after_each(function()
    vim.schedule       = orig.schedule
    diff.get_change_id = orig.get_change_id
    diff.get_parent_ids = orig.get_parent_ids
    diff.fetch_base    = orig.fetch_base
    diff.diff_async    = orig.diff_async
    diff.find_conflicts = orig.find_conflicts
    signs.place        = orig.place
    cache.clear(bufnr)
    base_cache._clear()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    os.remove(tmpfile)
  end)

  it("change_base sets base_rev and re-fetches the base for the new rev", function()
    jj_init.change_base("main", bufnr)

    local e = cache.get(bufnr)
    eq("main", e.base_rev)
    eq("main", resolved_revs[#resolved_revs])  -- parent ids resolved against new rev
    eq("main", fetched_revs[#fetched_revs])     -- base content fetched for new rev
    eq("base of main\n", e.base_text)
  end)

  it("change_base invalidates cached base_text + parent ids", function()
    -- Seed as if a previous @- fetch had populated the entry.
    local e0 = cache.get(bufnr)
    e0.base_text        = "stale\n"
    e0.parent_change_id = "pcid-@-"
    e0.parent_commit_id = "ppid-@-"

    jj_init.change_base("main", bufnr)

    local e = cache.get(bufnr)
    eq("base of main\n", e.base_text)        -- not the stale value
    eq("pcid-main", e.parent_change_id)
    eq("ppid-main", e.parent_commit_id)
  end)

  it("reset_base restores @- and re-fetches the default base", function()
    jj_init.change_base("main", bufnr)
    jj_init.reset_base(bufnr)

    local e = cache.get(bufnr)
    eq("@-", e.base_rev)
    eq("@-", resolved_revs[#resolved_revs])
    eq("@-", fetched_revs[#fetched_revs])
  end)

  it("change_base with empty rev is a no-op (keeps default base)", function()
    jj_init.change_base("", bufnr)
    eq("@-", cache.get(bufnr).base_rev)
    eq(0, #fetched_revs)
  end)
end)
