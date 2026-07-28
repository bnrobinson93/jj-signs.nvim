-- Black-box verticals for the blame feature, driven through the public API with a
-- scripted jj adapter. blame_spec covers the pure parsers; this covers the thread
-- fetch(annotate) → resolve → show → float, and the full-file split — the plumbing
-- the jj-adapter extraction rerouted.
local jjsigns = require("jj-signs")
local cache   = require("jj-signs.cache")
local float   = require("jj-signs.float")
local fake_jj = require("test.fake_jj")
local h       = require("test.helpers")
local eq      = h.eq

require("jj-signs.config").setup({})

-- annotate stdout parsed by blame.parse_annotate: "<cid> <date> <email>: <text>".
local ANNOTATE = table.concat({
  "aaaaaaaa1 2026-01-15 alice@example.com: line one",
  "bbbbbbbb2 2026-01-10 bob@example.com: line two",
}, "\n") .. "\n"

local function make_buf(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".txt")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
  cache.set(buf, { root = "/fake", change_id = "cid", hunks = {} })
  return buf
end

describe("blame_line popup vertical", function()
  local buf, orig_open, opened
  before_each(function()
    buf = make_buf({ "line one", "line two" })
    opened = nil
    orig_open = float.open
    float.open = function(lines, opts) opened = { lines = lines, opts = opts } end
  end)
  after_each(function()
    float.open = orig_open
    fake_jj.restore()
    cache.clear(buf)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("resolves the cursor line's change and floats its jj show output", function()
    fake_jj.install({
      annotate = ANNOTATE,
      show = "Change aaaaaaaa1\nAuthor: alice\n\n    the description\n",
    })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    jjsigns.blame_line()  -- opts nil → message-only (diff stripped)

    assert.is_not_nil(opened, "expected a float to open for the cursor line")
    -- build_show_lines keeps the header + description (trailing blanks trimmed).
    eq({ "Change aaaaaaaa1", "Author: alice", "", "    the description" }, opened.lines)
    eq(1, fake_jj.calls.annotate)
    eq(1, fake_jj.calls.show)
  end)

  it("does not float and notifies when jj show fails", function()
    fake_jj.install({ annotate = ANNOTATE, show = false })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    local notified
    local orig_notify = vim.notify
    vim.notify = function(msg) notified = msg end

    jjsigns.blame_line()

    vim.notify = orig_notify
    eq(nil, opened)
    assert.is_truthy(notified and notified:match("jj show failed"))
  end)

  it("notifies when the cursor line has no blame entry", function()
    fake_jj.install({ annotate = ANNOTATE })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "l1", "l2", "l3" })
    vim.api.nvim_win_set_cursor(0, { 3, 0 })  -- no annotate entry for line 3

    local notified
    local orig_notify = vim.notify
    vim.notify = function(msg) notified = msg end

    jjsigns.blame_line()

    vim.notify = orig_notify
    eq(nil, opened)
    assert.is_truthy(notified and notified:match("no blame for line"))
    eq(0, fake_jj.calls.show)  -- never reached jj show
  end)
end)

describe("blame full-file split vertical", function()
  local buf, orig_schedule
  before_each(function()
    buf = make_buf({ "line one", "line two" })
    orig_schedule = vim.schedule
    vim.schedule = function(fn) fn() end  -- run window mutation inline
  end)
  after_each(function()
    vim.schedule = orig_schedule
    fake_jj.restore()
    -- Close any jj-blame window/buffer the test opened.
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      local ok, name = pcall(vim.api.nvim_buf_get_name, b)
      if ok and name:match("jj%-blame://") then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    cache.clear(buf)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("opens a scroll-bound split with per-line change · author · date", function()
    fake_jj.install({ annotate = ANNOTATE })

    jjsigns.blame()

    -- M.blame leaves the new blame window current.
    local blame_buf = vim.api.nvim_get_current_buf()
    local name = vim.api.nvim_buf_get_name(blame_buf)
    assert.is_truthy(name:match("jj%-blame://"), "expected a jj-blame:// buffer, got " .. name)

    eq({
      "aaaaaaaa • alice • 2026-01-15",
      "bbbbbbbb • bob • 2026-01-10",
    }, vim.api.nvim_buf_get_lines(blame_buf, 0, -1, false))
    eq(false, vim.bo[blame_buf].modifiable)
  end)
end)
