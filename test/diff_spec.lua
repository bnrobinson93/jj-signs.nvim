local diff = require("jj-signs.diff")
local h = require("test.helpers")
local eq = h.eq

-- Bootstrap minimal config so diff module can reference config.config.jj_cmd
require("jj-signs.config").setup({})

describe("diff.parse_diff_line", function()
  it("parses an add hunk header", function()
    local hunk = diff.parse_diff_line("@@ -0,0 +1,3 @@")
    eq("add", hunk.type)
    eq(0, hunk.removed.start)
    eq(0, hunk.removed.count)
    eq(1, hunk.added.start)
    eq(3, hunk.added.count)
    eq(3, hunk.vend)
  end)

  it("parses a delete hunk header", function()
    local hunk = diff.parse_diff_line("@@ -5,2 +5,0 @@")
    eq("delete", hunk.type)
    eq(5, hunk.removed.start)
    eq(2, hunk.removed.count)
    eq(5, hunk.added.start)
    eq(0, hunk.added.count)
  end)

  it("parses a change hunk header", function()
    local hunk = diff.parse_diff_line("@@ -10,4 +10,6 @@")
    eq("change", hunk.type)
    eq(10, hunk.removed.start)
    eq(4, hunk.removed.count)
    eq(10, hunk.added.start)
    eq(6, hunk.added.count)
    eq(15, hunk.vend)
  end)

  it("handles single-line hunks (no count field)", function()
    local hunk = diff.parse_diff_line("@@ -1 +1 @@")
    eq(1, hunk.removed.count)
    eq(1, hunk.added.count)
  end)
end)

describe("diff.parse_hunks", function()
  it("returns empty table for empty output", function()
    eq({}, diff.parse_hunks(""))
    eq({}, diff.parse_hunks(nil))
  end)

  it("parses a single add hunk with lines", function()
    local raw = table.concat({
      "diff --git a/foo.txt b/foo.txt",
      "--- a/foo.txt",
      "+++ b/foo.txt",
      "@@ -0,0 +1,2 @@",
      "+added line 1",
      "+added line 2",
    }, "\n")

    local hunks = diff.parse_hunks(raw)
    eq(1, #hunks)
    eq("add", hunks[1].type)
    eq(2, #hunks[1].added.lines)
    eq("added line 1", hunks[1].added.lines[1])
    eq("added line 2", hunks[1].added.lines[2])
  end)

  it("parses a single delete hunk", function()
    local raw = table.concat({
      "@@ -3,2 +3,0 @@",
      "-removed line 1",
      "-removed line 2",
    }, "\n")

    local hunks = diff.parse_hunks(raw)
    eq(1, #hunks)
    eq("delete", hunks[1].type)
    eq(2, #hunks[1].removed.lines)
  end)

  it("parses a change hunk (mixed - and + lines)", function()
    local raw = table.concat({
      "@@ -5,1 +5,1 @@",
      "-old line",
      "+new line",
    }, "\n")

    local hunks = diff.parse_hunks(raw)
    eq(1, #hunks)
    eq("change", hunks[1].type)
    eq("old line", hunks[1].removed.lines[1])
    eq("new line", hunks[1].added.lines[1])
  end)

  it("ignores context lines when calculating added range", function()
    local raw = table.concat({
      "@@ -38,6 +38,8 @@",
      " context1",
      " context2",
      " context3",
      "+added line 1",
      "+added line 2",
      " context4",
      " context5",
      " context6",
    }, "\n")
    local hunks = diff.parse_hunks(raw)
    eq(1, #hunks)
    eq("add", hunks[1].type)
    eq(41, hunks[1].added.start)
    eq(42, hunks[1].vend)
    eq(2, hunks[1].added.count)
    eq(0, hunks[1].removed.count)
    eq(2, #hunks[1].added.lines)
  end)

  it("parses multiple hunks", function()
    local raw = table.concat({
      "@@ -0,0 +1,1 @@",
      "+new at top",
      "@@ -10,1 +11,0 @@",
      "-deleted",
      "@@ -20,1 +20,1 @@",
      "-old",
      "+new",
    }, "\n")

    local hunks = diff.parse_hunks(raw)
    eq(3, #hunks)
    eq("add",    hunks[1].type)
    eq("delete", hunks[2].type)
    eq("change", hunks[3].type)
  end)
end)

describe("diff.find_conflicts", function()
  it("detects no conflicts in clean buffer", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line1", "line2", "line3" })
    local conflicts = diff.find_conflicts(bufnr)
    eq({}, conflicts)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("detects a JJ conflict block", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "before",
      "<<<<<<< Conflict 1 of 1",
      "base line",
      ">>>>>>> Conflict 1 of 1 ends",
      "after",
    })
    local conflicts = diff.find_conflicts(bufnr)
    eq(1, #conflicts)
    eq("conflict", conflicts[1].type)
    eq(2, conflicts[1].added.start)
    eq(4, conflicts[1].vend)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)

describe("diff.merge_hunks", function()
  it("returns diff hunks unchanged when no conflicts", function()
    local diff_hunks = {
      { type = "add", added = { start = 1, count = 1, lines = {} }, removed = { start = 0, count = 0, lines = {} }, vend = 1, head = "" },
    }
    local result = diff.merge_hunks(diff_hunks, {})
    eq(1, #result)
    eq("add", result[1].type)
  end)

  it("conflict hunks override overlapping diff hunks", function()
    local diff_hunks = {
      { type = "change", added = { start = 2, count = 3, lines = {} }, removed = { start = 2, count = 3, lines = {} }, vend = 4, head = "" },
    }
    local conflict_hunks = {
      { type = "conflict", added = { start = 2, count = 3, lines = {} }, removed = { start = 2, count = 3, lines = {} }, vend = 4, head = "conflict" },
    }
    local result = diff.merge_hunks(diff_hunks, conflict_hunks)
    eq(1, #result)
    eq("conflict", result[1].type)
  end)
end)
