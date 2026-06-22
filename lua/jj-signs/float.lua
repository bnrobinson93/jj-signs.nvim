--- Shared floating-window helper. Both hunks.preview_hunk and blame.blame_line
--- render a scratch float relative to the cursor that self-closes on the next
--- cursor move; this is the single implementation they call.

local api = vim.api
local config = require("jj-signs.config")

local M = {}

--- Open a self-closing scratch float showing `lines`, positioned per
--- config.preview_config (relative="cursor", row=1, col=0, style="minimal",
--- border="rounded" by default). Width is clamped to [20, 80] around the widest
--- line + 2; height to [#lines, 20]. Closes on the next CursorMoved/BufLeave/
--- WinLeave.
--- @param lines string[]
--- @param opts? { filetype?: string, enter?: boolean }
--- @return integer win, integer buf
function M.open(lines, opts)
  opts = opts or {}

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if opts.filetype and opts.filetype ~= "" then
    vim.bo[buf].filetype = opts.filetype
  end

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, #l)
  end
  width = math.min(math.max(width + 2, 20), 80)

  local pc = config.config.preview_config or {}
  local win = api.nvim_open_win(buf, opts.enter or false, {
    relative = pc.relative or "cursor",
    row      = pc.row or 1,
    col      = pc.col or 0,
    width    = width,
    height   = math.min(#lines, 20),
    style    = pc.style or "minimal",
    border   = pc.border or "rounded",
  })

  api.nvim_create_autocmd({ "CursorMoved", "BufLeave", "WinLeave" }, {
    once = true,
    callback = function()
      if api.nvim_win_is_valid(win) then
        api.nvim_win_close(win, true)
      end
    end,
  })

  return win, buf
end

return M
