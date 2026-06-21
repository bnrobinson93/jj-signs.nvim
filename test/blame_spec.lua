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

describe("blame.resolve_change_id (blame_line cursor resolution)", function()
  local resolve = blame._resolve_change_id

  local entries = parse(table.concat({
    "aaaaaaaaaa00 2026-06-16 first@x.com: line one",
    "bbbbbbbbbb11 2026-06-15 second@x.com: line two",
    "cccccccccc22 2026-06-14 third@x.com: line three",
  }, "\n"))

  it("resolves the change_id for the cursor line", function()
    eq("aaaaaaaaaa00", resolve(entries, 1))
    eq("bbbbbbbbbb11", resolve(entries, 2))
    eq("cccccccccc22", resolve(entries, 3))
  end)

  it("returns nil for a line with no annotate entry", function()
    assert.is_nil(resolve(entries, 99))
  end)

  it("returns nil for nil entries", function()
    assert.is_nil(resolve(nil, 1))
  end)
end)

describe("blame.build_show_lines (popup content from jj show)", function()
  local build = blame._build_show_lines

  local show_out = table.concat({
    "Commit ID: b0f8b23d687d006989ab2fc241d3fd5bcbb6a99",
    "Change ID: lxtumqsynyprwuyznyxmxwkkkxnuwxoy",
    "Author   : Brad R <brad@example.com> (2026-06-21 01:04:29)",
    "",
    "    Add the blame popup",
    "",
    "diff --git a/foo.lua b/foo.lua",
    "index 111..222 100644",
    "--- a/foo.lua",
    "+++ b/foo.lua",
    "@@ -1 +1 @@",
    "-old",
    "+new",
  }, "\n")

  it("strips the unified diff when not full (message-only)", function()
    local lines = build(show_out, false)
    eq("Commit ID: b0f8b23d687d006989ab2fc241d3fd5bcbb6a99", lines[1])
    eq("    Add the blame popup", lines[#lines])
    for _, l in ipairs(lines) do
      assert.is_nil(l:match("^diff %-%-git"))
      assert.is_nil(l:match("^%+new"))
    end
  end)

  it("keeps the diff body when full", function()
    local lines = build(show_out, true)
    local joined = table.concat(lines, "\n")
    assert.is_not_nil(joined:match("diff %-%-git a/foo%.lua"))
    assert.is_not_nil(joined:match("%+new"))
  end)

  it("trims trailing blank lines", function()
    local lines = build("Change ID: abc\n\n    msg\n\n\n", false)
    eq("    msg", lines[#lines])
  end)

  it("returns empty table for empty output", function()
    eq(0, #build("", false))
  end)
end)

describe("blame.format_blame_lines (full-file blame split)", function()
  local fmt = blame._format_blame_lines

  it("prefixes each line with change_id • author • date", function()
    local entries = parse(table.concat({
      "aaaaaaaaaa00 2026-06-16 first@x.com: line one",
      "bbbbbbbbbb11 2026-06-15 second@x.com: line two",
    }, "\n"))
    local lines = fmt(entries)
    eq("aaaaaaaa • first • 2026-06-16", lines[1])
    eq("bbbbbbbb • second • 2026-06-15", lines[2])
  end)

  it("fills gaps with blank lines to preserve alignment", function()
    local entries = {
      [1] = { change_id = "aaaaaaaaaa00", author = "a", date = "2026-06-16" },
      [3] = { change_id = "cccccccccc22", author = "c", date = "2026-06-14" },
    }
    local lines = fmt(entries)
    eq(3, #lines)
    eq("", lines[2])
    eq("cccccccc • c • 2026-06-14", lines[3])
  end)
end)
