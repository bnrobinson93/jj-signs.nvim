local fixtures = require("test.fixtures")
local helpers  = require("test.async_helpers")
local jj_init  = require("jj-signs.init")
local cache    = require("jj-signs.cache")

describe("integration: attach", function()
  -- Skip if jj not available
  if vim.fn.executable("jj") == 0 then
    pending("jj binary not found — skipping attach integration tests")
    return
  end

  local root, bufnr

  before_each(function()
    jj_init.setup({})
    root  = fixtures.make_jj_repo()
    local filepath = root .. "/test.lua"
    bufnr = vim.fn.bufadd(filepath)
    vim.fn.bufload(bufnr)
  end)

  after_each(function()
    pcall(jj_init.detach, bufnr)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    fixtures.cleanup(root)
  end)

  it("populates cache after attach", function()
    jj_init.attach(bufnr)
    local ok = helpers.wait_for_refresh(bufnr, 3000)
    assert.is_true(ok, "refresh did not complete within timeout")
    local entry = cache.get(bufnr)
    assert.is_not_nil(entry)
    assert.equals(root, entry.root)
  end)
end)
