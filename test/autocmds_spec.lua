local autocmds = require("jj-signs.autocmds")
local cache    = require("jj-signs.cache")
local config   = require("jj-signs.config")

describe("autocmds.schedule_refresh visibility deferral", function()
  local BUF = 42

  -- saved real implementations
  local real_fn_win_findbuf
  local real_api_buf_is_valid
  local real_api_buf_line_count
  local real_bo
  local real_jjsigns

  local refreshed --- @type integer[]  buffers passed to refresh()
  local win_count --- @type integer     how many windows show BUF

  before_each(function()
    config.setup({})

    refreshed = {}
    win_count = 1

    real_fn_win_findbuf      = vim.fn.win_findbuf
    real_api_buf_is_valid    = vim.api.nvim_buf_is_valid
    real_api_buf_line_count  = vim.api.nvim_buf_line_count
    real_bo                  = vim.bo

    vim.fn.win_findbuf = function(_)
      local out = {}
      for i = 1, win_count do out[i] = i end
      return out
    end
    vim.api.nvim_buf_is_valid   = function(_) return true end
    vim.api.nvim_buf_line_count = function(_) return 10 end

    -- vim.bo[BUF].buftype == "" (normal buffer)
    vim.bo = setmetatable({}, { __index = function() return { buftype = "" } end })

    -- Stub the refresh target so the throttled wrapper records calls instead
    -- of hitting jj. The throttle resolves require("jj-signs") at call time.
    real_jjsigns = package.loaded["jj-signs"]
    package.loaded["jj-signs"] = {
      refresh = function(bufnr) table.insert(refreshed, bufnr) end,
    }
  end)

  after_each(function()
    vim.fn.win_findbuf            = real_fn_win_findbuf
    vim.api.nvim_buf_is_valid    = real_api_buf_is_valid
    vim.api.nvim_buf_line_count  = real_api_buf_line_count
    vim.bo                       = real_bo
    package.loaded["jj-signs"]   = real_jjsigns
    cache.clear(BUF)
  end)

  it("no window: sets update_on_view, fires no refresh", function()
    win_count = 0
    cache.set(BUF, { update_on_view = false })

    autocmds.schedule_refresh(BUF)

    assert.is_true(cache.get(BUF).update_on_view)
    assert.equals(0, #refreshed)
  end)

  it("window present: clears update_on_view, fires throttled refresh", function()
    win_count = 1
    cache.set(BUF, { update_on_view = true })

    autocmds.schedule_refresh(BUF)

    assert.is_false(cache.get(BUF).update_on_view)
    assert.equals(1, #refreshed)
    assert.equals(BUF, refreshed[1])
  end)

  it("WinEnter handler: deferred flag set re-schedules and clears flag", function()
    -- Buffer became visible again; flag was set by an earlier deferred refresh.
    win_count = 1
    cache.set(BUF, { update_on_view = true })

    autocmds._on_win_view({ buf = BUF })

    -- _on_win_view clears the flag, then schedule_refresh runs (window present)
    -- and leaves it cleared while firing the throttled refresh.
    assert.is_false(cache.get(BUF).update_on_view)
    assert.equals(1, #refreshed)
  end)

  it("WinEnter handler: no deferred flag does nothing", function()
    win_count = 1
    cache.set(BUF, { update_on_view = false })

    autocmds._on_win_view({ buf = BUF })

    assert.equals(0, #refreshed)
  end)

  it("WinEnter handler: no cache entry does nothing", function()
    win_count = 1
    -- no cache.set for BUF

    autocmds._on_win_view({ buf = BUF })

    assert.equals(0, #refreshed)
  end)
end)
