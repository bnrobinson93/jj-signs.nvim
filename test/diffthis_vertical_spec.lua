-- Black-box vertical for diffthis, rerouted through the new jj.file_show adapter.
-- Only cli_spec touched it before (dispatch routing); this drives the thread
-- file_show → temp file → `vert diffsplit`, plus the failure notify.
local jjsigns = require("jj-signs")
local cache   = require("jj-signs.cache")
local fake_jj = require("test.fake_jj")
local h       = require("test.helpers")
local eq      = h.eq

require("jj-signs.config").setup({})

local function buf_named(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local ok, n = pcall(vim.api.nvim_buf_get_name, b)
    if ok and n:match(name) then return b end
  end
end

describe("diffthis vertical", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".txt")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "working copy" })
    vim.api.nvim_set_current_buf(buf)
    cache.set(buf, { root = "/fake", change_id = "cid", hunks = {} })
  end)

  after_each(function()
    fake_jj.restore()
    vim.cmd("silent! diffoff!")
    -- Close every window except one, then wipe the diff/scratch buffers.
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      pcall(vim.api.nvim_win_close, w, true)
    end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      local n = vim.api.nvim_buf_get_name(b)
      if n:match("@%-:") or b == buf then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
    end
    cache.clear(buf)
  end)

  it("opens a diff split against the file at the given revision", function()
    fake_jj.install({ file_show = "at rev line1\nat rev line2\n" })

    jjsigns.diffthis("@-")

    eq(1, fake_jj.calls.file_show)
    local rev_buf = buf_named("@%-:")
    assert.is_not_nil(rev_buf, "expected a '@-:<file>' diff buffer")
    eq({ "at rev line1", "at rev line2" }, vim.api.nvim_buf_get_lines(rev_buf, 0, -1, false))
    eq(false, vim.bo[rev_buf].modifiable)
    -- Diff mode is active in the current (split) window.
    eq(true, vim.wo.diff)
  end)

  it("notifies and opens no split when jj file show fails", function()
    fake_jj.install({ file_show = false })

    local notified
    local orig_notify = vim.notify
    vim.notify = function(msg) notified = msg end

    jjsigns.diffthis("@-")

    vim.notify = orig_notify
    assert.is_truthy(notified and notified:match("could not get file at @%-"))
    eq(nil, buf_named("@%-:"))
  end)
end)
