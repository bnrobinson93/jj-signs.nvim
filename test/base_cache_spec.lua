local cache_mod  = require("jj-signs.cache")
local jj_init    = require("jj-signs.init")
local h          = require("test.helpers")
local eq         = h.eq

require("jj-signs.config").setup({})

describe("cache.base_get / base_set", function()
  before_each(function() cache_mod.base_clear() end)

  it("returns nil for unknown key", function()
    eq(nil, cache_mod.base_get("unknown", "x", "y"))
  end)

  it("returns stored text for known key", function()
    cache_mod.base_set("/f", "pcid", "ppid", "hello\n")
    eq("hello\n", cache_mod.base_get("/f", "pcid", "ppid"))
  end)

  it("differs by parent ids", function()
    cache_mod.base_set("/f", "pcid", "ppid", "a")
    eq(nil, cache_mod.base_get("/f", "pcid2", "ppid"))
    eq(nil, cache_mod.base_get("/f", "pcid", "ppid2"))
  end)
end)

describe("cache.base_gc", function()
  local bufs

  before_each(function()
    cache_mod.base_clear()
    bufs = {}
  end)

  after_each(function()
    for _, b in ipairs(bufs) do
      cache_mod.clear(b)
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
    cache_mod.base_clear()
  end)

  local function make_buf(name)
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(b, name)
    bufs[#bufs + 1] = b
    return b
  end

  it("keeps base entries referenced by a live buffer, drops the rest", function()
    local fa = vim.fn.tempname()
    local ba = make_buf(fa)
    cache_mod.set(ba, {
      root = "/r", parent_change_id = "p", parent_commit_id = "q", base_rev = "@-",
    })
    cache_mod.base_set(fa, "p", "q", "ta", "@-")
    cache_mod.base_set("/stale", "p", "q", "tb", "@-")

    cache_mod.base_gc()

    eq("ta", cache_mod.base_get(fa, "p", "q"))
    eq(nil,  cache_mod.base_get("/stale", "p", "q"))
  end)

  it("clears all when no buffer references any base key", function()
    cache_mod.base_set("/a", "p", "q", "ta")
    cache_mod.base_gc()
    eq(nil, cache_mod.base_get("/a", "p", "q"))
  end)
end)

describe("base content shared across refresh", function()
  local orig_system
  local orig_schedule
  local tmpfile
  local bufnr

  before_each(function()
    cache_mod.base_clear()

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
  -- the shared base content rather than spawning a second `jj file show`.
  it("second buffer with same file+parent hits cached base, no second fetch", function()
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

    -- Buffer A: no cached base yet → fetches, populates the shared store.
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
    eq("base content\n", cache_mod.base_get(tmpfile, "pcid", "ppid"))

    -- Buffer B (same file, same parent): base_text nil again → cached-base hit.
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
