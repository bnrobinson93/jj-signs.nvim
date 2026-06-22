--- Shared floating-window helper tests. Light: assert win/buf valid, filetype
--- applied via the modern API, and the width clamp formula.

local api = vim.api
local float = require("jj-signs.float")
local config = require("jj-signs.config")
local h = require("test.helpers")
local eq = h.eq

describe("float.open", function()
  before_each(function()
    config.setup()
    -- Headless default is 80 cols; widen so a max-width float is not shrunk to fit.
    vim.o.columns = 200
    vim.o.lines = 50
  end)

  it("returns a valid window and scratch buffer with the lines set", function()
    local win, buf = float.open({ "hello", "world" })
    assert.is_true(api.nvim_win_is_valid(win))
    assert.is_true(api.nvim_buf_is_valid(buf))
    eq({ "hello", "world" }, api.nvim_buf_get_lines(buf, 0, -1, false))
    api.nvim_win_close(win, true)
  end)

  it("sets filetype via the modern buffer-option API", function()
    local win, buf = float.open({ "+added" }, { filetype = "diff" })
    eq("diff", vim.bo[buf].filetype)
    api.nvim_win_close(win, true)
  end)

  it("clamps width to a minimum of 20", function()
    local win = float.open({ "x" })
    eq(20, api.nvim_win_get_width(win))
    api.nvim_win_close(win, true)
  end)

  it("clamps width to a maximum of 80", function()
    local win = float.open({ string.rep("x", 200) })
    eq(80, api.nvim_win_get_width(win))
    api.nvim_win_close(win, true)
  end)

  it("sizes width to widest line + 2 between the clamps", function()
    local win = float.open({ string.rep("x", 30) })
    eq(32, api.nvim_win_get_width(win))
    api.nvim_win_close(win, true)
  end)
end)
