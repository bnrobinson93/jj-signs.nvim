-- Black-box vertical for M.detach: the teardown thread that this refactor
-- rewrote when it folded base_cache into cache.lua and replaced init.detach's
-- hand-built key set with cache.base_gc(). Asserts the observable outcome —
-- detaching one buffer evicts its (now-unreferenced) shared base and any orphan,
-- while a second live buffer's base survives — plus signs cleared and the
-- watcher ref released.
local jjsigns = require("jj-signs")
local cache   = require("jj-signs.cache")
local signs   = require("jj-signs.signs")
local watcher = require("jj-signs.watcher")
local h       = require("test.helpers")
local eq      = h.eq

require("jj-signs.config").setup({})

describe("detach vertical", function()
  local bufA, bufB, nameA, nameB, orig_stop, stopped

  before_each(function()
    -- Two attached buffers on different files/roots, each with cached base.
    nameA = vim.fn.tempname() .. ".txt"
    nameB = vim.fn.tempname() .. ".txt"
    bufA = vim.api.nvim_create_buf(false, true); vim.api.nvim_buf_set_name(bufA, nameA)
    bufB = vim.api.nvim_create_buf(false, true); vim.api.nvim_buf_set_name(bufB, nameB)

    cache.set(bufA, { root = "/rA", change_id = "a", hunks = {},
      parent_change_id = "pA", parent_commit_id = "cA", base_rev = "@-" })
    cache.set(bufB, { root = "/rB", change_id = "b", hunks = {},
      parent_change_id = "pB", parent_commit_id = "cB", base_rev = "@-" })

    cache.base_clear()
    cache.base_set(nameA, "pA", "cA", "baseA\n", "@-")
    cache.base_set(nameB, "pB", "cB", "baseB\n", "@-")
    cache.base_set("/orphan", "pO", "cO", "baseO\n", "@-")  -- referenced by no buffer

    orig_stop = watcher.stop
    stopped = {}
    watcher.stop = function(root) stopped[#stopped + 1] = root end
  end)

  after_each(function()
    watcher.stop = orig_stop
    cache.clear(bufA); cache.clear(bufB); cache.base_clear()
    pcall(vim.api.nvim_buf_delete, bufA, { force = true })
    pcall(vim.api.nvim_buf_delete, bufB, { force = true })
  end)

  it("evicts the detached buffer's base and orphans, keeps a live buffer's base", function()
    jjsigns.detach(bufA)

    -- Detached buffer gone; the other stays attached.
    eq(false, jjsigns.is_attached(bufA))
    eq(true,  jjsigns.is_attached(bufB))

    -- base_gc: A's base and the orphan evicted; B's base retained.
    eq(nil,       cache.base_get(nameA, "pA", "cA"))
    eq(nil,       cache.base_get("/orphan", "pO", "cO"))
    eq("baseB\n", cache.base_get(nameB, "pB", "cB"))
  end)

  it("clears placed signs and releases the watcher for the detached root", function()
    -- Place a real sign on A, then detach and confirm it is gone.
    signs.place(bufA, { { type = "add", head = "", vend = 1,
      added = { start = 1, count = 1, lines = {}, lnums = { 1 } },
      removed = { start = 1, count = 0, lines = {} } } })

    jjsigns.detach(bufA)

    local marks = vim.api.nvim_buf_get_extmarks(bufA, signs.ns, 0, -1, {})
    eq(0, #marks)
    eq({ "/rA" }, stopped)  -- watcher.stop called once, for A's root only
  end)
end)
