local diff = require("jj-signs.diff")
local h = require("test.helpers")
local eq = h.eq

require("jj-signs.config").setup({})

-- vim.diff() reference result with the same opts diff_async uses internally.
local function ref(base, buf)
  local r = vim.diff(base, buf, { result_type = "unified", ctxlen = 3 })
  return (r and r ~= "") and r or nil
end

-- Drive the libuv event loop until diff_async's callback fires, then return
-- its result. In the real test VM the worker runs asynchronously, so we wait.
local function diff_sync(base, buf)
  local done = false
  local result
  diff.diff_async(base, buf, { ctxlen = 3 }, function(r)
    result = r
    done = true
  end)
  assert(vim.wait(2000, function() return done end), "diff_async callback never fired")
  return result
end

describe("diff.diff_async", function()
  it("matches vim.diff for an add", function()
    local base = "line1\nline2\n"
    local buf = "line1\nline2\nline3\n"
    eq(ref(base, buf), diff_sync(base, buf))
  end)

  it("matches vim.diff for a delete", function()
    local base = "line1\nline2\nline3\n"
    local buf = "line1\nline3\n"
    eq(ref(base, buf), diff_sync(base, buf))
  end)

  it("matches vim.diff for a change", function()
    local base = "line1\nold\nline3\n"
    local buf = "line1\nnew\nline3\n"
    eq(ref(base, buf), diff_sync(base, buf))
  end)

  it("returns nil for identical input", function()
    local base = "line1\nline2\nline3\n"
    eq(nil, diff_sync(base, base))
  end)
end)
