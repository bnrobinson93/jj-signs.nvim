--- Hunk utilities: navigation, preview, restore, summary.
--- find_hunk / find_nearest_hunk adapted from gitsigns.nvim (lewis6991/gitsigns.nvim) — MIT License

local api = vim.api
local config = require("jj-signs.config")
local cache = require("jj-signs.cache")
local float = require("jj-signs.float")

local M = {}

--- Dedicated namespace for inline preview marks, cleared on the next CursorMoved.
local preview_ns = api.nvim_create_namespace("jj-signs-preview-inline")

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
    elseif h.type == "topdelete" then
      s.deleted = s.deleted + h.removed.count
    elseif h.type == "changedelete" then
      local delta = math.min(h.added.count, h.removed.count)
      s.changed = s.changed + math.max(delta, 1)
      s.deleted = s.deleted + math.max(0, h.removed.count - h.added.count)
    elseif h.type == "conflict" then
      s.conflicts = s.conflicts + 1
    end
  end
  return s
end

--- The buffer line to land on for a hunk: delete/topdelete have no added lines,
--- so clamp to the line below the deletion (>= 1).
--- @param hunk JJSigns.Hunk
--- @return integer
local function hunk_target_line(hunk)
  if hunk.type == "delete" or hunk.type == "topdelete" then
    return math.max(1, hunk.added.start)
  end
  return hunk.added.start
end

--- Resolve an opts value, falling back to the configured `nav` default.
local function nav_opt(opts, key)
  if opts[key] ~= nil then return opts[key] end
  local nav = config.config.nav or {}
  return nav[key]
end

--- Jump to next/prev/first/last hunk in the current buffer.
--- @param direction "next" | "prev" | "first" | "last"
--- @param opts? { wrap?: boolean, preview?: boolean|"inline", foldopen?: boolean, count?: integer, navigation_message?: boolean }
function M.nav_hunk(direction, opts)
  opts = opts or {}
  local bufnr = api.nvim_get_current_buf()
  local entry = cache.get(bufnr)
  if not entry or #entry.hunks == 0 then
    vim.notify("jj-signs: no hunks", vim.log.levels.INFO)
    return
  end

  local wrap = nav_opt(opts, "wrap")
  if wrap == nil then wrap = true end
  local count = math.max(opts.count or 1, 1)

  -- Advance `count` hunks, re-seeding from each landing line so successive
  -- next/prev steps move hunk-by-hunk (count is a no-op for first/last).
  local lnum = api.nvim_win_get_cursor(0)[1]
  local idx
  for _ = 1, count do
    local next_idx = M.find_nearest_hunk(lnum, entry.hunks, direction, wrap)
    if not next_idx then break end
    idx = next_idx
    lnum = hunk_target_line(entry.hunks[idx])
  end
  if not idx then return end

  api.nvim_win_set_cursor(0, { lnum, 0 })

  local foldopen = nav_opt(opts, "foldopen")
  if foldopen == nil then foldopen = true end
  if foldopen then vim.cmd("normal! zv") end

  local nav_msg = nav_opt(opts, "navigation_message")
  if nav_msg == nil then nav_msg = true end
  if nav_msg then
    api.nvim_echo({ { ("Hunk %d of %d"):format(idx, #entry.hunks) } }, false, {})
  end

  local preview = nav_opt(opts, "preview")
  if preview == "inline" then
    M.preview_hunk_inline()
  elseif preview then
    M.preview_hunk()
  end
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

  float.open(lines, { filetype = "diff" })
end

--- Inline preview of the hunk under cursor: render `removed.lines` as dimmed
--- virtual lines above the hunk and highlight the added lines, all in a
--- dedicated namespace cleared on the next CursorMoved. No floating window.
--- Mirrors the virt_lines + namespace pattern in signs.lua place_deleted_lines.
function M.preview_hunk_inline()
  local bufnr = api.nvim_get_current_buf()
  local entry = cache.get(bufnr)
  if not entry or #entry.hunks == 0 then return end

  local lnum = api.nvim_win_get_cursor(0)[1]
  local hunk = M.find_hunk(lnum, entry.hunks)
  if not hunk then
    vim.notify("jj-signs: cursor not on a hunk", vim.log.levels.INFO)
    return
  end

  api.nvim_buf_clear_namespace(bufnr, preview_ns, 0, -1)
  local line_count = api.nvim_buf_line_count(bufnr)

  -- Removed lines as dimmed virt_lines above the hunk.
  if #hunk.removed.lines > 0 then
    local anchor
    if hunk.type == "delete" or hunk.type == "topdelete" then
      anchor = hunk.added.start == 0 and 0 or hunk.added.start
    else
      anchor = hunk.added.start - 1
    end
    anchor = math.max(math.min(anchor, line_count - 1), 0)

    local virt = {}
    for _, l in ipairs(hunk.removed.lines) do
      virt[#virt + 1] = { { l, "JJSignsDeleteVirtLn" } }
    end

    pcall(api.nvim_buf_set_extmark, bufnr, preview_ns, anchor, 0, {
      virt_lines       = virt,
      virt_lines_above = true,
    })
  end

  -- Highlight the added lines of the hunk.
  if hunk.added.count > 0 then
    for l = math.max(hunk.added.start, 1), hunk.vend do
      if l >= 1 and l <= line_count then
        pcall(api.nvim_buf_set_extmark, bufnr, preview_ns, l - 1, 0, {
          line_hl_group = "JJSignsAddLn",
        })
      end
    end
  end

  -- Clear the preview on the next cursor move.
  api.nvim_create_autocmd("CursorMoved", {
    once = true,
    callback = function()
      if api.nvim_buf_is_valid(bufnr) then
        api.nvim_buf_clear_namespace(bufnr, preview_ns, 0, -1)
      end
    end,
  })
end

function M.restore_hunk(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local entry = cache.get(bufnr)
  if not entry then return end

  local lnum = api.nvim_win_get_cursor(0)[1]
  local hunk = M.find_hunk(lnum, entry.hunks)
  if not hunk then
    vim.notify("jj-signs: no hunk at cursor", vim.log.levels.WARN)
    return
  end

  local start0 = hunk.added.start - 1
  local end0   = hunk.added.start + hunk.added.count - 1

  if hunk.added.start == 0 then
    start0 = 0
    end0   = 0
  end

  api.nvim_buf_set_lines(bufnr, start0, end0, false, hunk.removed.lines)
  vim.cmd("silent! write!")
end

--- Reset the whole buffer to the comparison-base content (base_rev, default @-),
--- discarding every working-copy change. The gitsigns `reset_buffer` analog and
--- the buffer-wide counterpart to restore_hunk. base_text is the cached file as
--- of base_rev; nvim_buf_get_lines-style splitting drops the trailing newline.
--- @param bufnr integer?
function M.reset_buffer(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local entry = cache.get(bufnr)
  if not entry or not entry.base_text then
    vim.notify("jj-signs: no base content to reset to", vim.log.levels.WARN)
    return
  end

  local base_lines = vim.split(entry.base_text, "\n")
  if base_lines[#base_lines] == "" then table.remove(base_lines) end

  api.nvim_buf_set_lines(bufnr, 0, -1, false, base_lines)
  vim.cmd("silent! write!")
end

function M.diffthis(rev)
	rev = rev or "@-"
	local bufnr = api.nvim_get_current_buf()
	local filepath = api.nvim_buf_get_name(bufnr)
	local entry = cache.get(bufnr)
	if not entry then return end

	local cmd = { config.config.jj_cmd }
	if config.config.jj_repo then
		vim.list_extend(cmd, { "--repository", config.config.jj_repo })
	end
	vim.list_extend(cmd, { "file", "show", "--revision", rev, "--", filepath })

	vim.system(cmd, { text = true, cwd = entry.root }, function(result)
		if result.code ~= 0 then
			vim.schedule(function()
				vim.notify("jj-signs: could not get file at " .. rev, vim.log.levels.ERROR)
			end)
			return
		end
		vim.schedule(function()
			local tmp = vim.fn.tempname()
			local f = io.open(tmp, "w")
			if f then
				f:write(result.stdout)
				f:close()
			end
			vim.cmd("vert diffsplit " .. vim.fn.fnameescape(tmp))
			local tmpbuf = api.nvim_get_current_buf()
			vim.bo[tmpbuf].bufhidden = "wipe"
			vim.bo[tmpbuf].modifiable = false
			api.nvim_buf_set_name(tmpbuf, rev .. ":" .. vim.fn.fnamemodify(filepath, ":t"))
		end)
	end)
end

function M.diffthis_rev()
	vim.ui.input({ prompt = "Revision: ", default = "@-" }, function(input)
		if input and input ~= "" then
			M.diffthis(input)
		end
	end)
end

return M
