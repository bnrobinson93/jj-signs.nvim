local wd = require("jj-signs.word_diff")
local h  = require("test.helpers")
local eq = h.eq

require("jj-signs.config").setup({})

local run = wd._run_word_diff

describe("word_diff.run_word_diff", function()
  it("returns empty regions for identical lines", function()
    local r, a = run({ "hello world" }, { "hello world" })
    eq(0, #r)
    eq(0, #a)
  end)

  it("detects full-line replacement", function()
    local r, a = run({ "aaa" }, { "bbb" })
    eq(1, #a)
    eq(0, a[1].start_col)
    eq(3, a[1].end_col)
  end)

  it("detects partial word change", function()
    -- "aXb" → "aYb": only middle char differs
    local r, a = run({ "aXb" }, { "aYb" })
    eq(1, #a)
    eq(1, a[1].start_col)  -- 0-indexed: 'a' = 1 byte offset
    eq(2, a[1].end_col)
  end)

  it("lnum in region matches pair index (1-indexed)", function()
    local removed = { "line one old", "line two old" }
    local added   = { "line one new", "line two new" }
    local _, a = run(removed, added)
    -- Each changed line produces one region; lnum should be 1 and 2
    local lnums = {}
    for _, reg in ipairs(a) do lnums[reg.lnum] = true end
    eq(true, lnums[1])
    eq(true, lnums[2])
  end)

  it("handles more removed lines than added (processes min)", function()
    local r, a = run({ "line1", "line2", "line3" }, { "lineX" })
    -- Only 1 pair processed (min = 1)
    local max_lnum = 0
    for _, reg in ipairs(a) do max_lnum = math.max(max_lnum, reg.lnum) end
    assert.is_true(max_lnum <= 1)
  end)

  it("returns empty for empty line arrays", function()
    local r, a = run({}, {})
    eq(0, #r)
    eq(0, #a)
  end)
end)

describe("word_diff.place_word_diff memoization", function()
  local bufnr
  local change_hunk = {
    type    = "change",
    head    = "",
    added   = { start = 1, count = 1, lines = { "aXb" } },
    removed = { start = 1, count = 1, lines = { "aYb" } },
    vend    = 1,
  }

  before_each(function()
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "aXb", "tail" })
  end)

  after_each(function()
    wd.clear_word_diff(bufnr)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("reuses regions on a repeated place with the same change_id", function()
    local orig = vim.diff
    local calls = 0
    vim.diff = function(a, b, o) calls = calls + 1; return orig(a, b, o) end
    local ok, err = pcall(function()
      wd.place_word_diff(bufnr, { change_hunk }, "cid1")
      wd.place_word_diff(bufnr, { change_hunk }, "cid1")  -- memo hit, no recompute
    end)
    vim.diff = orig
    assert(ok, err)
    eq(1, calls)
  end)

  it("recomputes when the change_id flips", function()
    local orig = vim.diff
    local calls = 0
    vim.diff = function(a, b, o) calls = calls + 1; return orig(a, b, o) end
    local ok, err = pcall(function()
      wd.place_word_diff(bufnr, { change_hunk }, "cid1")
      wd.place_word_diff(bufnr, { change_hunk }, "cid2")  -- new revision → recompute
    end)
    vim.diff = orig
    assert(ok, err)
    eq(2, calls)
  end)

  it("clear_word_diff drops the memo so the next place recomputes", function()
    local orig = vim.diff
    local calls = 0
    vim.diff = function(a, b, o) calls = calls + 1; return orig(a, b, o) end
    local ok, err = pcall(function()
      wd.place_word_diff(bufnr, { change_hunk }, "cid1")
      wd.clear_word_diff(bufnr)
      wd.place_word_diff(bufnr, { change_hunk }, "cid1")  -- memo gone → recompute
    end)
    vim.diff = orig
    assert(ok, err)
    eq(2, calls)
  end)
end)
