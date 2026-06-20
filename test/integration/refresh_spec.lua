local fixtures = require("test.fixtures")
local helpers  = require("test.async_helpers")
local jj_init  = require("jj-signs.init")
local cache    = require("jj-signs.cache")

describe("integration: refresh after jj op", function()
  -- Skip if jj not available
  if vim.fn.executable("jj") == 0 then
    pending("jj binary not found — skipping refresh integration tests")
    return
  end

  local root, bufnr

  before_each(function()
    jj_init.setup({})
    root  = fixtures.make_jj_repo()
    local filepath = root .. "/test.lua"
    bufnr = vim.fn.bufadd(filepath)
    vim.fn.bufload(bufnr)
    jj_init.attach(bufnr)
    helpers.wait_for_refresh(bufnr, 3000)
  end)

  after_each(function()
    pcall(jj_init.detach, bufnr)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    fixtures.cleanup(root)
  end)

  it("updates hunks when file changes on disk", function()
    local filepath = root .. "/test.lua"
    -- Write a modified version
    local f = assert(io.open(filepath, "w"))
    f:write("-- original\nlocal x = 1\nlocal y = 2\n")  -- added line
    f:close()

    -- refresh()'s fast-path skips run_diff when the on-disk mtime matches the
    -- cached one. mtime has 1-second granularity, and this write lands in the
    -- same second as the initial refresh, so push the mtime forward to force
    -- the disk-change path deterministically.
    local future = os.time() + 10
    assert((vim.uv or vim.loop).fs_utime(filepath, future, future))

    jj_init.refresh(bufnr)

    -- Wait on the hunks themselves, not dirty==false: dirty is already false
    -- from the initial refresh, so a dirty check would pass before run_diff's
    -- async callback lands the new hunks.
    local ok = helpers.wait_until(function()
      local e = cache.get(bufnr)
      return e ~= nil and #e.hunks > 0
    end, 3000)

    assert.is_true(ok, "expected at least one hunk after adding a line")
  end)
end)
