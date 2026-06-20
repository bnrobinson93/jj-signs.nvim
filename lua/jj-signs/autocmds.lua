local api = vim.api
local config = require("jj-signs.config")
local cache = require("jj-signs.cache")
local async = require("jj-signs.async")

local M = {}

-- Throttled refresh: one refresh runs at a time per buffer; a call arriving
-- mid-flight queues exactly one follow-up so no state change is dropped.
local throttled_refresh = async.throttle_async(
  function(bufnr) require("jj-signs").refresh(bufnr) end,
  function(bufnr) return bufnr end
)

--- Schedule a refresh for bufnr.
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

  -- Buffer visible; fire throttled refresh
  throttled_refresh(bufnr)
end

--- No-op: retained for callers (init.lua detach). Throttle replaces the
--- per-buffer debounce timer, so there is nothing to cancel.
--- @param bufnr integer
function M.cancel(bufnr) end

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
