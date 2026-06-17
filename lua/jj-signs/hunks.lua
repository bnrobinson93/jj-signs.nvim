--- Hunk utilities: navigation, preview, restore, summary.
--- find_hunk / find_nearest_hunk adapted from gitsigns.nvim (lewis6991/gitsigns.nvim) — MIT License

local api = vim.api
local config = require("jj-signs.config")
local cache = require("jj-signs.cache")

local M = {}

--- @param lnum  integer
--- @param hunks JJSigns.Hunk[]?
--- @return JJSigns.Hunk?, integer?
function M.find_hunk(lnum, hunks)
  for i, hunk in ipairs(hunks or {}) do
    if lnum == 1 and hunk.added.start == 0 and hunk.vend == 0 then
      return hunk, i
    end
    if hunk.added.start <= lnum and hunk.vend >= lnum then
      return hunk, i
    end
  end
end

--- @param lnum      integer
--- @param hunks     JJSigns.Hunk[]
--- @param direction "next" | "prev" | "first" | "last"
--- @param wrap      boolean?
--- @return integer?
function M.find_nearest_hunk(lnum, hunks, direction, wrap)
  if #hunks == 0 then return end
  if direction == "first" then return 1 end
  if direction == "last" then return #hunks end

  if direction == "next" then
    if hunks[1].added.start > lnum then return 1 end
    for i = #hunks, 1, -1 do
      if hunks[i].added.start <= lnum then
        if i + 1 <= #hunks and hunks[i + 1].added.start > lnum then
          return i + 1
        elseif wrap then
          return 1
        end
      end
    end
  elseif direction == "prev" then
    if math.max(hunks[#hunks].vend, 1) < lnum then return #hunks end
    for i = 1, #hunks do
      if lnum <= math.max(hunks[i].vend, 1) then
        if i > 1 and math.max(hunks[i - 1].vend, 1) < lnum then
          return i - 1
        elseif wrap then
          return #hunks
        end
      end
    end
  end
end

--- @param hunks JJSigns.Hunk[]
--- @return { added: integer, changed: integer, deleted: integer, conflicts: integer }
function M.get_summary(hunks)
  local s = { added = 0, changed = 0, deleted = 0, conflicts = 0 }
  for _, h in ipairs(hunks or {}) do
    if h.type == "add" then
      s.added = s.added + h.added.count
    elseif h.type == "delete" then
      s.deleted = s.deleted + h.removed.count
    elseif h.type == "change" then
      local delta = math.min(h.added.count, h.removed.count)
      s.changed = s.changed + delta
      s.added   = s.added   + math.max(0, h.added.count - delta)
      s.deleted = s.deleted + math.max(0, h.removed.count - delta)
    elseif h.type == "conflict" then
      s.conflicts = s.conflicts + 1
    end
  end
  return s
end

--- Jump to next/prev/first/last hunk in the current buffer.
--- @param direction "next" | "prev" | "first" | "last"
function M.nav_hunk(direction)
  local bufnr = api.nvim_get_current_buf()
  local entry = cache.get(bufnr)
  if not entry or #entry.hunks == 0 then
    vim.notify("jj-signs: no hunks", vim.log.levels.INFO)
    return
  end

  local lnum = api.nvim_win_get_cursor(0)[1]
  local idx = M.find_nearest_hunk(lnum, entry.hunks, direction, true)
  if not idx then return end

  local hunk = entry.hunks[idx]
  local target = hunk.type == "delete" and math.max(1, hunk.added.start)
    or hunk.added.start
  api.nvim_win_set_cursor(0, { target, 0 })
end

--- Open a floating preview of the hunk under cursor.
function M.preview_hunk()
  local bufnr = api.nvim_get_current_buf()
  local entry = cache.get(bufnr)
  if not entry or #entry.hunks == 0 then return end

  local lnum = api.nvim_win_get_cursor(0)[1]
  local hunk = M.find_hunk(lnum, entry.hunks)
  if not hunk then
    vim.notify("jj-signs: cursor not on a hunk", vim.log.levels.INFO)
    return
  end

  local lines = {}
  for _, l in ipairs(hunk.removed.lines) do
    lines[#lines + 1] = "-" .. l
  end
  for _, l in ipairs(hunk.added.lines) do
    lines[#lines + 1] = "+" .. l
  end

  if #lines == 0 then
    lines = { "(no content)" }
  end

  local float_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  api.nvim_buf_set_option(float_buf, "filetype", "diff")

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, #l)
  end
  width = math.min(math.max(width + 2, 20), 80)

  local win = api.nvim_open_win(float_buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = math.min(#lines, 20),
    style = "minimal",
    border = "rounded",
  })

  -- Close on any cursor move or buffer leave
  api.nvim_create_autocmd({ "CursorMoved", "BufLeave", "WinLeave" }, {
    once = true,
    callback = function()
      if api.nvim_win_is_valid(win) then
        api.nvim_win_close(win, true)
      end
    end,
  })
end

--- Restore the file at the hunk under cursor to its @- state.
--- This runs `jj restore` on the whole file — JJ has no CLI for partial hunk restore.
function M.restore_hunk()
  local bufnr = api.nvim_get_current_buf()
  local entry = cache.get(bufnr)
  if not entry then return end

  local filepath = api.nvim_buf_get_name(bufnr)

  local answer = vim.fn.confirm(
    "Restore " .. vim.fn.fnamemodify(filepath, ":t") .. " from @-? (cannot be undone)",
    "&Yes\n&No",
    2
  )
  if answer ~= 1 then return end

  local cmd = { config.config.jj_cmd }
  if config.config.jj_repo then
    vim.list_extend(cmd, { "--repository", config.config.jj_repo })
  end
  vim.list_extend(cmd, { "restore", "--from", "@-", "--", filepath })

  vim.system(cmd, { cwd = entry.root },
    function(result)
      vim.schedule(function()
        if result.code == 0 then
          vim.cmd("edit")  -- reload buffer from disk
        else
          vim.notify("jj restore failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
        end
      end)
    end
  )
end

return M
