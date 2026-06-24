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

  it("updates hunks when the buffer content changes", function()
    -- Signs reflect the live buffer (diffed against cached base via vim.diff),
    -- so add a line to the buffer and refresh.
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "local y = 2" })

    jj_init.refresh(bufnr)

    -- Wait on the hunks themselves: the diff is async, so poll until they land.
    local ok = helpers.wait_until(function()
      local e = cache.get(bufnr)
      return e ~= nil and #e.hunks > 0
    end, 3000)

    assert.is_true(ok, "expected at least one hunk after adding a line")
  end)
end)
