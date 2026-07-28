-- Self-test for the fake jj adapter harness: proves install() scripts the real
-- jj module table's functions (so captured `local jj` references see the fake)
-- and restore() puts the originals back.
local jj      = require("jj-signs.jj")
local fake_jj = require("test.fake_jj")
local h       = require("test.helpers")
local eq      = h.eq

require("jj-signs.config").setup({})

describe("fake_jj harness", function()
  after_each(function() fake_jj.restore() end)

  it("scripts adapter responses and counts calls", function()
    fake_jj.install({
      root = "/r", change_id = "abc", bookmark = "main", description = "wip",
      parents = { "pc", "pp" }, base = "base\n",
      annotate = "ann\n", show = "show\n", file_show = "fs\n",
    })

    local root; jj.get_root("/f", function(r) root = r end)
    eq("/r", root)

    local id, bm, desc; jj.get_change_id("/r", function(a, b, c) id, bm, desc = a, b, c end)
    eq({ "abc", "main", "wip" }, { id, bm, desc })

    local pc, pp; jj.get_parent_ids("/r", "@-", function(a, b) pc, pp = a, b end)
    eq({ "pc", "pp" }, { pc, pp })

    local base; jj.fetch_base("/f", "/r", "@-", function(b) base = b end)
    eq("base\n", base)

    local ann; jj.annotate("/r", "/f", function(s) ann = s end)
    eq("ann\n", ann)

    eq(1, fake_jj.calls.get_root)
    eq(1, fake_jj.calls.annotate)
  end)

  it("false scripts a failure (nil stdout); root=false means not a repo", function()
    fake_jj.install({ root = false, annotate = false, show = false, file_show = false })

    local root = "sentinel"; jj.get_root("/f", function(r) root = r end)
    eq(nil, root)

    local ann = "sentinel"; jj.annotate("/r", "/f", function(s) ann = s end)
    eq(nil, ann)
  end)

  it("restore() puts the real functions back", function()
    local real = jj.get_change_id
    fake_jj.install({})
    assert.are_not.equal(real, jj.get_change_id)
    fake_jj.restore()
    assert.are.equal(real, jj.get_change_id)
  end)
end)
