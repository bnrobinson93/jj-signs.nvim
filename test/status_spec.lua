require("jj-signs.config").setup({})

local api    = vim.api
local status = require("jj-signs.status")
local h      = require("test.helpers")
local eq     = h.eq

--- Build a minimal hunk (mirrors signs_spec).
local function mk(type, added_start, added_count, removed_count, vend_override)
  local vend = vend_override ~= nil and vend_override
    or (added_start + math.max(added_count - 1, 0))
  return {
    type    = type,
    head    = "",
    added   = { start = added_start, count = added_count,   lines = {} },
    removed = { start = added_start, count = removed_count, lines = {} },
    vend    = vend,
  }
end

describe("status.build_dict", function()
  it("maps summary deleted -> removed and shortens head", function()
    local d = status.build_dict({ mk("add", 1, 3, 0) }, "kkpqsvxyabcdef")
    eq(3, d.added)
    eq(0, d.changed)
    eq(0, d.removed)
    eq(0, d.conflicts)
    eq("kkpqsvxy", d.head)
  end)

  it("counts changed and removed", function()
    local d = status.build_dict({ mk("change", 5, 2, 2), mk("delete", 9, 0, 4, 9) }, nil)
    eq(2, d.changed)
    eq(4, d.removed)
    eq("", d.head)
  end)

  it("counts conflicts", function()
    local d = status.build_dict({ mk("conflict", 2, 1, 1) }, nil)
    eq(1, d.conflicts)
  end)
end)

describe("status.format (default formatter)", function()
  it("emits +N ~N -N", function()
    eq("+3 ~1 -2", status.format({ added = 3, changed = 1, removed = 2 }))
  end)

  it("omits zero parts", function()
    eq("+5", status.format({ added = 5, changed = 0, removed = 0 }))
    eq("~2 -1", status.format({ added = 0, changed = 2, removed = 1 }))
    eq("", status.format({ added = 0, changed = 0, removed = 0 }))
  end)
end)

describe("status.update", function()
  local bufnr

  before_each(function()
    bufnr = api.nvim_create_buf(false, true)
  end)

  after_each(function()
    if api.nvim_buf_is_valid(bufnr) then
      api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it("populates buffer-local vars", function()
    status.update(bufnr, { mk("add", 1, 2, 0), mk("change", 8, 1, 1) }, "abcdefgh1234")

    local d = vim.b[bufnr].jjsigns_status_dict
    eq(2, d.added)
    eq(1, d.changed)
    eq(0, d.removed)
    eq("abcdefgh", d.head)
    eq("+2 ~1", vim.b[bufnr].jjsigns_status)
    eq("abcdefgh", vim.b[bufnr].jjsigns_head)
  end)

  it("status string omits zero counts", function()
    status.update(bufnr, { mk("add", 1, 4, 0) }, "zzzz")
    eq("+4", vim.b[bufnr].jjsigns_status)
  end)

  it("clear nils the vars", function()
    status.update(bufnr, { mk("add", 1, 1, 0) }, "x")
    status.clear(bufnr)
    eq(nil, vim.b[bufnr].jjsigns_status_dict)
    eq(nil, vim.b[bufnr].jjsigns_status)
    eq(nil, vim.b[bufnr].jjsigns_head)
  end)
end)
