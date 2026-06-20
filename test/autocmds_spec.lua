local autocmds = require("jj-signs.autocmds")
local cache    = require("jj-signs.cache")
local config   = require("jj-signs.config")

describe("autocmds.schedule_refresh visibility deferral", function()
  local BUF = 42

  -- saved real implementations
  local real_api_get_buf_windows
  local real_api_buf_is_valid
  local real_api_buf_line_count
  local real_bo
  local real_uv
  local real_loop

  local started_timers --- @type table list of fake timers started
  local win_count      --- @type integer how many windows show BUF

  before_each(function()
    config.setup({})

    started_timers = {}
    win_count      = 1

    real_api_get_buf_windows = vim.api.nvim_get_buf_windows
    real_api_buf_is_valid    = vim.api.nvim_buf_is_valid
    real_api_buf_line_count  = vim.api.nvim_buf_line_count
    real_bo                  = vim.bo
    real_uv                  = vim.uv
    real_loop                = vim.loop

    vim.api.nvim_get_buf_windows = function(_)
      local out = {}
      for i = 1, win_count do out[i] = i end
      return out
    end
    vim.api.nvim_buf_is_valid   = function(_) return true end
    vim.api.nvim_buf_line_count = function(_) return 10 end

    -- vim.bo[BUF].buftype == "" (normal buffer)
    vim.bo = setmetatable({}, { __index = function() return { buftype = "" } end })

    local fake_uv = {
      new_timer = function()
        local t = {
          start = function(self) table.insert(started_timers, self); return 0 end,
          stop  = function() end,
          close = function() end,
        }
        return t
      end,
    }
    vim.uv   = fake_uv
    vim.loop = fake_uv
  end)

  after_each(function()
    vim.api.nvim_get_buf_windows = real_api_get_buf_windows
    vim.api.nvim_buf_is_valid    = real_api_buf_is_valid
    vim.api.nvim_buf_line_count  = real_api_buf_line_count
    vim.bo                       = real_bo
    vim.uv                       = real_uv
    vim.loop                     = real_loop
    cache.clear(BUF)
  end)

  it("no window: sets update_on_view, starts no timer", function()
    win_count = 0
    cache.set(BUF, { update_on_view = false })

    autocmds.schedule_refresh(BUF)

    assert.is_true(cache.get(BUF).update_on_view)
    assert.equals(0, #started_timers)
  end)

  it("window present: clears update_on_view, starts timer", function()
    win_count = 1
    cache.set(BUF, { update_on_view = true })

    autocmds.schedule_refresh(BUF)

    assert.is_false(cache.get(BUF).update_on_view)
    assert.equals(1, #started_timers)
  end)

  it("WinEnter handler: deferred flag set re-schedules and clears flag", function()
    -- Buffer became visible again; flag was set by an earlier deferred refresh.
    win_count = 1
    cache.set(BUF, { update_on_view = true })

    autocmds._on_win_view({ buf = BUF })

    -- _on_win_view clears the flag, then schedule_refresh runs (window present)
    -- and leaves it cleared while starting the debounce timer.
    assert.is_false(cache.get(BUF).update_on_view)
    assert.equals(1, #started_timers)
  end)

  it("WinEnter handler: no deferred flag does nothing", function()
    win_count = 1
    cache.set(BUF, { update_on_view = false })

    autocmds._on_win_view({ buf = BUF })

    assert.equals(0, #started_timers)
  end)

  it("WinEnter handler: no cache entry does nothing", function()
    win_count = 1
    -- no cache.set for BUF

    autocmds._on_win_view({ buf = BUF })

    assert.equals(0, #started_timers)
  end)
end)
