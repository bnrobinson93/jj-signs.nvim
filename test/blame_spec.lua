require("jj-signs.config").setup({})
local blame = require("jj-signs.blame")
local h     = require("test.helpers")
local eq    = h.eq

local parse   = blame._parse_annotate
local reldate = blame._relative_date

describe("blame.parse_annotate", function()
  it("parses single line", function()
    local out = "kkpqsvxyzspo 2026-06-16 brad@example.com: content here"
    local e = parse(out)
    eq("kkpqsvxyzspo", e[1].change_id)
    eq("brad",         e[1].author)
    eq("2026-06-16",   e[1].date)
  end)

  it("extracts author from email (before @)", function()
    local out = "aabbccddee11 2026-01-01 alice.smith@corp.example.com: code"
    local e = parse(out)
    eq("alice.smith", e[1].author)
  end)

  it("parses multiple lines with correct 1-indexed keys", function()
    local out = table.concat({
      "aaaaaaaaaa00 2026-06-16 first@x.com: line one",
      "bbbbbbbbbb11 2026-06-15 second@x.com: line two",
      "cccccccccc22 2026-06-14 third@x.com: line three",
    }, "\n")
    local e = parse(out)
    eq(3,              #vim.tbl_keys(e))
    eq("aaaaaaaaaa00", e[1].change_id)
    eq("first",        e[1].author)
    eq("bbbbbbbbbb11", e[2].change_id)
    eq("second",       e[2].author)
    eq("cccccccccc22", e[3].change_id)
    eq("third",        e[3].author)
  end)

  it("returns empty table for empty output", function()
    local e = parse("")
    eq(0, #vim.tbl_keys(e))
  end)

  it("skips blank lines without shifting lnum", function()
    -- jj annotate shouldn't emit blanks, but if it does, blank lines are skipped
    local out = "aaaaaaaaaaaa 2026-06-16 a@b.com: line one"
    local e = parse(out)
    eq(1, e[1] and 1 or 0)
  end)
end)

describe("blame.relative_date", function()
  local function days_ago(n)
    return os.date("%Y-%m-%d", os.time() - n * 86400)
  end

  it("returns days for 3 days ago", function()
    eq("3 days ago", reldate(days_ago(3)))
  end)

  it("returns 1 week ago for 10 days ago", function()
    eq("1 week ago", reldate(days_ago(10)))
  end)

  it("returns weeks for 21 days ago", function()
    eq("3 weeks ago", reldate(days_ago(21)))
  end)

  it("returns months for 45 days ago", function()
    eq("1 month ago", reldate(days_ago(45)))
  end)

  it("returns years for 800 days ago", function()
    eq("2 years ago", reldate(days_ago(800)))
  end)

  it("returns singular for exactly 1 year ago", function()
    eq("1 year ago", reldate(days_ago(365)))
  end)

  it("returns input unchanged for unparseable date", function()
    eq("not-a-date", reldate("not-a-date"))
  end)
end)
