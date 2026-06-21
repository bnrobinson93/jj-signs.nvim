--- CLI tests: subcommand dispatch, completion filtering, and unknown-action
--- handling for the :JJSigns command interface.

local cli = require("jj-signs.cli")
local h = require("test.helpers")
local eq = h.eq

describe("cli.dispatch", function()
  it("resolves a known subcommand to a function", function()
    eq("function", type(cli.dispatch("nav_hunk")))
    eq("function", type(cli.dispatch("refresh")))
    eq("function", type(cli.dispatch("toggle_current_line_blame")))
    eq("function", type(cli.dispatch("blame_line")))
    eq("function", type(cli.dispatch("blame")))
  end)

  it("returns the same function the module exports", function()
    eq(require("jj-signs").nav_hunk, cli.dispatch("nav_hunk"))
  end)

  it("returns nil for an unknown subcommand", function()
    assert.is_nil(cli.dispatch("does_not_exist"))
  end)

  it("returns nil for a nil name", function()
    assert.is_nil(cli.dispatch(nil))
  end)
end)

describe("cli.complete", function()
  it("filters subcommands by prefix", function()
    eq({ "nav_hunk" }, cli.complete("nav"))
  end)

  it("returns all matches sharing a prefix", function()
    local m = cli.complete("diff")
    table.sort(m)
    eq({ "diffthis", "diffthis_rev" }, m)
  end)

  it("returns every subcommand for an empty lead", function()
    local m = cli.complete("")
    assert.is_true(#m >= 9)
  end)

  it("returns nothing for a non-matching lead", function()
    eq({}, cli.complete("zzz"))
  end)
end)

describe("cli.run", function()
  it("notifies on an unknown subcommand instead of erroring", function()
    local notified
    local orig = vim.notify
    vim.notify = function(msg) notified = msg end
    local ok = pcall(cli.run, { "bogus_action" })
    vim.notify = orig
    assert.is_true(ok)
    assert.is_not_nil(notified)
  end)

  it("notifies on missing subcommand", function()
    local notified
    local orig = vim.notify
    vim.notify = function(msg) notified = msg end
    cli.run({})
    vim.notify = orig
    assert.is_not_nil(notified)
  end)

  it("forwards positional args to the resolved function", function()
    local jjsigns = require("jj-signs")
    local got
    local orig = jjsigns.nav_hunk
    jjsigns.nav_hunk = function(dir) got = dir end
    cli.run({ "nav_hunk", "next" })
    jjsigns.nav_hunk = orig
    eq("next", got)
  end)
end)
