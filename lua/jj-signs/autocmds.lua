local api = vim.api
local config = require("jj-signs.config")
local cache = require("jj-signs.cache")

local M = {}

-- Timer table keyed by bufnr for debouncing
local timers = {} --- @type table<integer, uv_timer_t>

--- @param bufnr integer
local function cancel_timer(bufnr)
  local t = timers[bufnr]
  if t then
    t:stop()
    t:close()
    timers[bufnr] = nil
  end
end

--- Schedule a debounced refresh for bufnr.
--- @param bufnr integer
function M.schedule_refresh(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then return end

  -- Defer when buffer is not visible in any window; WinEnter/BufWinEnter
  -- will re-trigger the refresh once it becomes viewable.
  if #api.nvim_get_buf_windows(bufnr) == 0 then
    local entry = cache.get(bufnr)
    if entry then
      entry.update_on_view = true
    end
    return
  end

  -- Buffer is visible: any pending deferred refresh is now being serviced.
  local entry = cache.get(bufnr)
  if entry then
    entry.update_on_view = false
  end

  -- Skip non-normal buffers
  local bt = vim.bo[bufnr].buftype
  if bt ~= "" then return end

  -- Skip large files
  local line_count = api.nvim_buf_line_count(bufnr)
  if line_count > config.config.max_file_length then return end

  cancel_timer(bufnr)

  local timer = (vim.uv or vim.loop).new_timer()
  timers[bufnr] = timer
  timer:start(config.config.update_debounce, 0, function()
    cancel_timer(bufnr)
    vim.schedule(function()
      require("jj-signs").refresh(bufnr)
    end)
  end)
end

--- @param bufnr integer
function M.cancel(bufnr)
  cancel_timer(bufnr)
end

--- WinEnter/BufWinEnter callback: re-run a refresh that was deferred while the
--- buffer had no window.
--- @param args { buf: integer }
function M._on_win_view(args)
  local b = args.buf
  local entry = cache.get(b)
  if entry and entry.update_on_view then
    entry.update_on_view = false
    M.schedule_refresh(b)
  end
end

function M.setup()
  local augroup = api.nvim_create_augroup("JJSigns", { clear = true })

  -- Re-apply highlights after colorscheme changes (keeps GitSigns* link valid).
  api.nvim_create_autocmd("ColorScheme", {
    group    = augroup,
    callback = function() require("jj-signs.signs").setup_highlights() end,
  })

  api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "FocusGained" }, {
    group    = augroup,
    callback = function(args)
      M.schedule_refresh(args.buf)
    end,
  })

  api.nvim_create_autocmd({ "WinEnter", "BufWinEnter" }, {
    group    = augroup,
    callback = M._on_win_view,
  })

  -- TextChanged/TextChangedI/InsertEnter/InsertLeave superseded by
  -- nvim_buf_attach's on_lines (see init.attach), which tracks the dirty line
  -- range so the diff can be narrowed instead of re-diffing the whole buffer.

  -- Invalidate root cache when jj ops happen (repo-level changes)
  api.nvim_create_autocmd("BufWritePost", {
    group   = augroup,
    pattern = "*.jj",
    callback = function()
      require("jj-signs.cache").invalidate_all()
    end,
  })

  if config.config.current_line_blame then
    require("jj-signs.blame").setup_autocmds(augroup)
  end
end

return M
