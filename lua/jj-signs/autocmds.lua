local api = vim.api
local config = require("jj-signs.config")

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
