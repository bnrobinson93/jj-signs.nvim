local base_cache = require("jj-signs.base_cache")
local cache_mod  = require("jj-signs.cache")
local jj_init    = require("jj-signs.init")
local h          = require("test.helpers")
local eq         = h.eq

require("jj-signs.config").setup({})

describe("base_cache.get", function()
  before_each(function() base_cache._clear() end)

  it("returns nil for unknown key", function()
    eq(nil, base_cache.get("unknown", "x", "y"))
  end)

  it("returns stored text for known key", function()
    base_cache.set("/f", "pcid", "ppid", "hello\n")
    eq("hello\n", base_cache.get("/f", "pcid", "ppid"))
  end)

  it("differs by parent ids", function()
    base_cache.set("/f", "pcid", "ppid", "a")
    eq(nil, base_cache.get("/f", "pcid2", "ppid"))
    eq(nil, base_cache.get("/f", "pcid", "ppid2"))
  end)
end)

describe("base_cache.evict_stale", function()
  before_each(function() base_cache._clear() end)

  it("removes entries not in active set", function()
    base_cache.set("/a", "p", "q", "ta")
    base_cache.set("/b", "p", "q", "tb")

    local active = {}
    active[base_cache.key("/a", "p", "q")] = true

    base_cache.evict_stale(active)

    eq("ta", base_cache.get("/a", "p", "q"))
    eq(nil,  base_cache.get("/b", "p", "q"))
  end)

  it("clears all when active set empty", function()
    base_cache.set("/a", "p", "q", "ta")
    base_cache.evict_stale({})
    eq(nil, base_cache.get("/a", "p", "q"))
  end)
end)

describe("base_cache shared across refresh", function()
  local orig_system
  local orig_schedule
  local tmpfile
  local bufnr

  before_each(function()
    base_cache._clear()

    tmpfile = vim.fn.tempname() .. ".txt"
    local f = assert(io.open(tmpfile, "w"))
    f:write("original\n")
    f:close()

    bufnr = vim.fn.bufadd(tmpfile)
    vim.fn.bufload(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "original", "MODIFIED" })

    orig_system   = vim.system
    orig_schedule = vim.schedule
    vim.schedule  = function(fn) fn() end
  end)

  after_each(function()
    vim.system   = orig_system
    vim.schedule = orig_schedule
    cache_mod.clear(bufnr)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    os.remove(tmpfile)
  end)

  -- Two buffers with same filepath+pcid+ppid share one fetch.
  -- Second refresh stands in for "buffer B, same file, same parent": its
  -- entry has base_text=nil (as C1 leaves a fresh buffer), so it must hit
  -- the shared base_cache rather than spawning a second `jj file show`.
  it("second buffer with same file+parent hits base_cache, no second fetch", function()
    local show_calls = 0
    vim.system = function(cmd, _, cb)
      if vim.tbl_contains(cmd, "log") then
        cb({ code = 0, stdout = "pcid ppid\n" })
      elseif vim.tbl_contains(cmd, "show") then
        show_calls = show_calls + 1
        cb({ code = 0, stdout = "base content\n" })
      else
        cb({ code = 0, stdout = "" })
      end
    end

    -- Buffer A: no cached base yet → fetches, populates base_cache.
    cache_mod.set(bufnr, {
      root             = "/fake",
      change_id        = "cid",
      mtime            = 0,
      hunks            = {},
      dirty            = false,
      base_text        = nil,
      parent_change_id = "pcid",
      parent_commit_id = "ppid",
    })
    jj_init.refresh(bufnr)
    eq(1, show_calls)
    eq("base content\n", base_cache.get(tmpfile, "pcid", "ppid"))

    -- Buffer B (same file, same parent): base_text nil again → base_cache hit.
    cache_mod.set(bufnr, {
      root             = "/fake",
      change_id        = "cid",
      mtime            = 0,
      hunks            = {},
      dirty            = false,
      base_text        = nil,
      parent_change_id = "pcid",
      parent_commit_id = "ppid",
    })
    jj_init.refresh(bufnr)

    eq(1, show_calls)  -- still one fetch total
  end)
end)
