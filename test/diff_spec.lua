local diff = require("jj-signs.diff")
local cache_mod = require("jj-signs.cache")
local jj_init = require("jj-signs.init")
local h = require("test.helpers")
local eq = h.eq

-- Bootstrap minimal config so diff module can reference config.config.jj_cmd
require("jj-signs.config").setup({})

describe("jj commands pass --ignore-working-copy", function()
  -- Regression guard: jj must never auto-snapshot the working copy in response to
  -- a read, or its op-log write re-triggers the watcher → refresh → jj read loop.
  local orig_system, orig_schedule, captured
  before_each(function()
    orig_system   = vim.system
    orig_schedule = vim.schedule
    vim.schedule  = function(fn) fn() end
    captured = nil
    vim.system = function(cmd, _, cb)
      captured = cmd
      cb({ code = 0, stdout = "a b\n" })
    end
  end)
  after_each(function()
    vim.system   = orig_system
    vim.schedule = orig_schedule
  end)

  local function has_flag() return captured and vim.tbl_contains(captured, "--ignore-working-copy") end

  it("get_change_id", function()
    diff.get_change_id("/r", function() end)
    assert.is_true(has_flag(), "get_change_id missing --ignore-working-copy")
  end)
  it("get_parent_ids", function()
    diff.get_parent_ids("/r", "@-", function() end)
    assert.is_true(has_flag(), "get_parent_ids missing --ignore-working-copy")
  end)
  it("fetch_base", function()
    diff.fetch_base("/r/f.txt", "/r", "@-", function() end)
    assert.is_true(has_flag(), "fetch_base missing --ignore-working-copy")
  end)
end)

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

  it("anchors a delete hunk at the line above the deletion (ctxlen 0)", function()
    -- Real vim.diff ctxlen=0 output for deleting line 5 of an 8-line file. The
    -- header new_start (4) is the deletion anchor: the line above the gap.
    local raw = table.concat({
      "@@ -5 +4,0 @@",
      "-5",
    }, "\n")
    local hunks = diff.parse_hunks(raw)
    eq(1, #hunks)
    eq("delete", hunks[1].type)
    eq(4, hunks[1].added.start)
    eq(4, hunks[1].vend)
    eq(0, hunks[1].added.count)
    eq(1, hunks[1].removed.count)
  end)

  it("anchors a top-of-file delete at line 0 (topdelete, ctxlen 0)", function()
    local raw = table.concat({
      "@@ -1 +0,0 @@",
      "-1",
    }, "\n")
    local hunks = diff.parse_hunks(raw)
    eq(1, #hunks)
    eq("delete", hunks[1].type)
    eq(0, hunks[1].added.start)
    eq(0, hunks[1].vend)
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

  it("tracks exact added line numbers in lnums", function()
    local raw = table.concat({
      "@@ -5,1 +5,1 @@",
      "-old",
      "+new",
    }, "\n")
    local hunks = diff.parse_hunks(raw)
    eq(1, #hunks)
    eq({ 5 }, hunks[1].added.lnums)
  end)

  it("tracks non-contiguous added line numbers in merged hunks", function()
    local raw = table.concat({
      "@@ -1,10 +1,10 @@",
      " context",
      " context",
      "-old A",
      "+new A",
      " context",
      " context",
      " context",
      " context",
      "-old B",
      "+new B",
      " context",
    }, "\n")
    local hunks = diff.parse_hunks(raw)
    eq(1, #hunks)
    -- new A is at new-file line 3 (after 2 context), new B at line 8
    eq({ 3, 8 }, hunks[1].added.lnums)
    eq(3, hunks[1].added.start)
    eq(8, hunks[1].vend)
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

describe("diff.has_conflict_marker", function()
  it("returns false for a clean buffer", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line1", "line2", "line3" })
    eq(false, diff.has_conflict_marker(bufnr))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("returns true when a conflict marker is present", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "before", "<<<<<<< Conflict 1 of 1", "after",
    })
    eq(true, diff.has_conflict_marker(bufnr))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("respects the line range", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "<<<<<<< Conflict 1 of 1", "a", "b", "c",
    })
    -- marker at line 1 (0-indexed 0); range [1,4) excludes it
    eq(false, diff.has_conflict_marker(bufnr, 1, 4))
    eq(true, diff.has_conflict_marker(bufnr, 0, 1))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)

describe("diff.find_conflicts range scan", function()
  it("scans only the given range and reports 1-based buffer lines", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "pad",                          -- 1
      "pad",                          -- 2
      "<<<<<<< Conflict 1 of 1",      -- 3
      "base",                         -- 4
      ">>>>>>> Conflict 1 of 1 ends", -- 5
      "tail",                         -- 6
    })
    -- Scan from line 3 (0-indexed 2) onward; offset preserved in output lnums.
    local conflicts = diff.find_conflicts(bufnr, 2, 6)
    eq(1, #conflicts)
    eq(3, conflicts[1].added.start)
    eq(5, conflicts[1].vend)
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

describe("diff.build_diff_opts", function()
  local config = require("jj-signs.config")

  after_each(function()
    config.setup({})
  end)

  it("forwards algorithm into the vim.diff opts", function()
    config.setup({ diff_opts = { algorithm = "patience" } })
    local o = diff.build_diff_opts({ result_type = "unified", ctxlen = 3 })
    eq("patience", o.algorithm)
    eq("unified", o.result_type)
    eq(3, o.ctxlen)
  end)

  it("forwards whitespace flags as vim.diff's native opt keys", function()
    config.setup({ diff_opts = { ignore_whitespace = true, ignore_whitespace_change = true } })
    local o = diff.build_diff_opts()
    eq(true, o.ignore_whitespace)
    eq(true, o.ignore_whitespace_change)
  end)

  it("defaults to myers with whitespace flags and linematch unset", function()
    config.setup({})
    local o = diff.build_diff_opts()
    eq("myers", o.algorithm)
    eq(false, o.indent_heuristic)
    eq(nil, o.ignore_whitespace)
    eq(nil, o.ignore_whitespace_change)
    eq(nil, o.linematch)
  end)

  it("ignore_whitespace collapses a whitespace-only hunk", function()
    local base = "foo\nbar\n"
    local buf  = "foo  \n  bar\n"

    config.setup({})
    h.neq("", vim.diff(base, buf, diff.build_diff_opts({ result_type = "unified", ctxlen = 3 })))

    config.setup({ diff_opts = { ignore_whitespace = true } })
    eq("", vim.diff(base, buf, diff.build_diff_opts({ result_type = "unified", ctxlen = 3 })))
  end)

  it("threads opts through word_diff's vim.diff call", function()
    config.setup({ diff_opts = { algorithm = "histogram" } })
    local orig = vim.diff
    local captured
    vim.diff = function(a, b, o)
      captured = o
      return orig(a, b, o)
    end
    local ok, err = pcall(function()
      require("jj-signs.word_diff")._run_word_diff({ "abc" }, { "abd" })
    end)
    vim.diff = orig
    assert(ok, err)
    eq("histogram", captured.algorithm)
    eq("indices", captured.result_type)
  end)
end)

describe("diff.get_parent_ids", function()
  local orig_system
  local orig_schedule

  before_each(function()
    orig_system = vim.system
    orig_schedule = vim.schedule
    vim.schedule = function(fn) fn() end
  end)

  after_each(function()
    vim.system = orig_system
    vim.schedule = orig_schedule
  end)

  it("parses stdout into change_id and commit_id", function()
    vim.system = function(_, _, cb)
      cb({ code = 0, stdout = "abc123 def456\n" })
    end
    local got_pcid, got_ppid
    diff.get_parent_ids("/fake/root", "@-", function(pcid, ppid)
      got_pcid = pcid
      got_ppid = ppid
    end)
    eq("abc123", got_pcid)
    eq("def456", got_ppid)
  end)

  it("returns nil, nil when jj command fails", function()
    vim.system = function(_, _, cb)
      cb({ code = 1, stdout = nil })
    end
    local got_pcid, got_ppid = "sentinel", "sentinel"
    diff.get_parent_ids("/fake/root", "@-", function(pcid, ppid)
      got_pcid = pcid
      got_ppid = ppid
    end)
    eq(nil, got_pcid)
    eq(nil, got_ppid)
  end)

  it("trims whitespace from stdout before splitting", function()
    vim.system = function(_, _, cb)
      cb({ code = 0, stdout = "  changeid   commitid  \n" })
    end
    local got_pcid, got_ppid
    diff.get_parent_ids("/fake/root", "@-", function(pcid, ppid)
      got_pcid = pcid
      got_ppid = ppid
    end)
    eq("changeid", got_pcid)
    eq("commitid", got_ppid)
  end)
end)

describe("refresh() modified-buffer base_text invalidation", function()
  local orig_system
  local orig_schedule
  local tmpfile
  local bufnr

  before_each(function()
    tmpfile = vim.fn.tempname() .. ".txt"
    local f = assert(io.open(tmpfile, "w"))
    f:write("original\n")
    f:close()

    bufnr = vim.fn.bufadd(tmpfile)
    vim.fn.bufload(bufnr)
    -- Modify buffer content so modified=true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "original", "MODIFIED" })

    orig_system = vim.system
    orig_schedule = vim.schedule
    vim.schedule = function(fn) fn() end
  end)

  after_each(function()
    vim.system = orig_system
    vim.schedule = orig_schedule
    cache_mod.clear(bufnr)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    os.remove(tmpfile)
  end)

  local function make_system_stub(parent_stdout, fetch_base_called_ref)
    return function(cmd, _, cb)
      if vim.tbl_contains(cmd, "log") then
        cb({ code = 0, stdout = parent_stdout })
      elseif vim.tbl_contains(cmd, "show") then
        if fetch_base_called_ref then fetch_base_called_ref.v = true end
        cb({ code = 0, stdout = "base content\n" })
      else
        cb({ code = 0, stdout = "" })
      end
    end
  end

  it("invalidates base_text and re-fetches when parent_change_id differs", function()
    cache_mod.set(bufnr, {
      root             = "/fake",
      change_id        = "cid",
      mtime            = 0,
      hunks            = {},
      dirty            = false,
      base_text        = "stale base\n",
      parent_change_id = "old_pcid",
      parent_commit_id = "ppid",
    })

    local called = { v = false }
    vim.system = make_system_stub("new_pcid ppid\n", called)

    jj_init.refresh(bufnr)

    eq(true, called.v)
    local e = cache_mod.get(bufnr)
    eq("new_pcid", e.parent_change_id)
    eq("ppid", e.parent_commit_id)
  end)

  it("invalidates base_text and re-fetches when only parent_commit_id differs", function()
    cache_mod.set(bufnr, {
      root             = "/fake",
      change_id        = "cid",
      mtime            = 0,
      hunks            = {},
      dirty            = false,
      base_text        = "stale base\n",
      parent_change_id = "pcid",
      parent_commit_id = "old_ppid",
    })

    local called = { v = false }
    vim.system = make_system_stub("pcid new_ppid\n", called)

    jj_init.refresh(bufnr)

    eq(true, called.v)
    local e = cache_mod.get(bufnr)
    eq("pcid", e.parent_change_id)
    eq("new_ppid", e.parent_commit_id)
  end)

  it("skips fetch_base when parent ids are unchanged (fast path)", function()
    cache_mod.set(bufnr, {
      root             = "/fake",
      change_id        = "cid",
      mtime            = 0,
      hunks            = {},
      dirty            = false,
      base_text        = "cached base\n",
      parent_change_id = "pcid",
      parent_commit_id = "ppid",
    })

    local called = { v = false }
    vim.system = make_system_stub("pcid ppid\n", called)

    jj_init.refresh(bufnr)

    eq(false, called.v)
  end)
end)
