local fixtures = require("test.fixtures")
local helpers  = require("test.async_helpers")
local jj_init  = require("jj-signs.init")
local cache    = require("jj-signs.cache")

describe("integration: watcher", function()
  -- Skip if jj not available
  if vim.fn.executable("jj") == 0 then
    pending("jj binary not found — skipping watcher integration tests")
    return
  end

  local root, bufnr

  before_each(function()
    jj_init.setup({})
    root  = fixtures.make_jj_repo()
    local filepath = root .. "/test.lua"
    bufnr = vim.fn.bufadd(filepath)
    vim.fn.bufload(bufnr)
    -- Display the buffer in a window. The watcher path runs through
    -- autocmds.schedule_refresh, which DEFERS when the buffer has no window.
    -- Without a window the watcher would fire but never refresh.
    vim.api.nvim_set_current_buf(bufnr)
    jj_init.attach(bufnr)
    helpers.wait_for_refresh(bufnr, 3000)
  end)

  after_each(function()
    pcall(jj_init.detach, bufnr)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    fixtures.cleanup(root)
  end)

  it("refreshes cache when jj new runs without explicit refresh", function()
    -- The working-copy change_id must update after the watcher fires. Capture
    -- the current one so we can assert it actually changed (a plain dirty==false
    -- check would pass trivially, since refresh already ran in before_each).
    local before = cache.get(bufnr)
    assert.is_not_nil(before)
    local old_change_id = before.change_id
    assert.is_not_nil(old_change_id)
    assert.is_not.equals("", old_change_id)

    -- Run jj new in the repo. This writes a new operation head; the watcher
    -- on .jj/repo/op_heads/ should fire and schedule a refresh on its own.
    vim.fn.system({ "jj", "--repository", root, "new", "-m", "next" })

    -- Wait for the watcher → schedule_refresh → refresh chain to land the new
    -- working-copy change_id into the cache. No explicit jj_init.refresh() call.
    local updated = helpers.wait_until(function()
      local e = cache.get(bufnr)
      return e ~= nil and e.dirty == false and e.change_id ~= old_change_id
    end, 5000)

    assert.is_true(updated, "watcher did not refresh cache to new change_id within timeout")
  end)
end)
