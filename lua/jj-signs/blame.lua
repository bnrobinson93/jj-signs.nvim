local api = vim.api
local config = require("jj-signs.config")

local M = {}
local blame_ns = api.nvim_create_namespace("jj-signs-blame")

local blame_cache = {}

local function relative_date(date_str)
	local y, mo, d = date_str:match("(%d+)-(%d+)-(%d+)")
	if not y then return date_str end
	local then_t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 0 })
	local diff = os.difftime(os.time(), then_t)
	local hours = math.floor(diff / 3600)
	if hours < 24 then
		return hours <= 1 and "1 hour ago" or (hours .. " hours ago")
	end
	local days = math.floor(hours / 24)
	if days < 7 then
		return days == 1 and "1 day ago" or (days .. " days ago")
	end
	local weeks = math.floor(days / 7)
	if weeks < 5 then
		return weeks == 1 and "1 week ago" or (weeks .. " weeks ago")
	end
	local months = math.floor(days / 30)
	if months < 12 then
		return months == 1 and "1 month ago" or (months .. " months ago")
	end
	local years = math.floor(days / 365)
	return years == 1 and "1 year ago" or (years .. " years ago")
end

local function format_blame(entry)
	local fmt = config.config.current_line_blame_opts.format
	local short_id = entry.change_id:sub(1, 8)
	local s = fmt:gsub("%%s", short_id)
	s = s:gsub("%%a", entry.author)
	s = s:gsub("%%r", relative_date(entry.date))
	return s
end

local function parse_annotate(output)
	local entries = {}
	local lnum = 1
	for line in (output .. "\n"):gmatch("([^\n]*)\n") do
		if line ~= "" then
			local change_id, date, email = line:match("^(%S+)%s+(%S+)%s+([^:]+):")
			if change_id then
				local author = email:match("^([^@]+)") or email
				entries[lnum] = { change_id = change_id, author = author, date = date }
			end
			lnum = lnum + 1
		end
	end
	return entries
end

function M.fetch(bufnr, root, filepath, cb)
	local cache_entry = require("jj-signs.cache").get(bufnr)
	local current_change_id = cache_entry and cache_entry.change_id or ""

	local bc = blame_cache[bufnr]
	if bc and bc.change_id == current_change_id and current_change_id ~= "" then
		cb(bc.entries)
		return
	end

	local cmd = { config.config.jj_cmd }
	if config.config.jj_repo then
		vim.list_extend(cmd, { "--repository", config.config.jj_repo })
	end
	vim.list_extend(cmd, { "annotate", "--color=never", "--", filepath })

	vim.system(cmd, { text = true, cwd = root }, function(result)
		if result.code ~= 0 then
			vim.schedule(function() cb(nil) end)
			return
		end
		local entries = parse_annotate(result.stdout)
		blame_cache[bufnr] = { change_id = current_change_id, entries = entries }
		vim.schedule(function() cb(entries) end)
	end)
end

function M.show(bufnr, lnum)
	local bc = blame_cache[bufnr]
	if not bc or not bc.entries[lnum] then return end

	local entry = bc.entries[lnum]
	local text = format_blame(entry)
	local pos = config.config.current_line_blame_opts.virt_text_pos or "eol"

	api.nvim_buf_set_extmark(bufnr, blame_ns, lnum - 1, 0, {
		virt_text     = { { text, "JJSignsCurrentLineBlame" } },
		virt_text_pos = pos,
		priority      = 100,
	})
end

function M.clear(bufnr)
	api.nvim_buf_clear_namespace(bufnr, blame_ns, 0, -1)
end

-- P4: on-demand blame popup (`blame_line`) and full-file blame split (`blame`).
-- Both are ADDITIVE to the inline EOL `current_line_blame` above and independent
-- of it: they reuse M.fetch's cached `jj annotate` entries but render on demand.

--- Resolve the change_id for a given 1-indexed line from annotate entries.
--- @param entries table?  output of parse_annotate (keyed by lnum)
--- @param lnum integer
--- @return string?
local function resolve_change_id(entries, lnum)
  local e = entries and entries[lnum]
  return e and e.change_id or nil
end

--- Build floating-window lines from `jj show` output. When `full` is false the
--- unified diff is stripped, leaving only the commit header + description.
--- @param output string  raw `jj show --color=never` stdout
--- @param full boolean?  keep the diff body when truthy
--- @return string[]
local function build_show_lines(output, full)
  local lines = {}
  for line in ((output or "") .. "\n"):gmatch("([^\n]*)\n") do
    if not full and line:match("^diff %-%-git") then break end
    lines[#lines + 1] = line
  end
  while #lines > 0 and lines[#lines] == "" do
    lines[#lines] = nil
  end
  return lines
end

--- Prefix each source line with `change_id • author • date` for the side split.
--- Gaps (lines without annotate data) become blank so alignment is preserved.
--- @param entries table  parse_annotate output keyed by lnum
--- @return string[]
local function format_blame_lines(entries)
  local max = 0
  for lnum in pairs(entries) do
    if lnum > max then max = lnum end
  end
  local lines = {}
  for i = 1, max do
    local e = entries[i]
    if e then
      lines[i] = string.format("%s • %s • %s", e.change_id:sub(1, 8), e.author, e.date)
    else
      lines[i] = ""
    end
  end
  return lines
end

--- Open a floating window (reuses hunks.preview_hunk's pattern) showing `lines`.
--- @param lines string[]
--- @param filetype string?
local function open_float(lines, filetype)
  local float_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  if filetype and filetype ~= "" then
    api.nvim_buf_set_option(float_buf, "filetype", filetype)
  end

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

  api.nvim_create_autocmd({ "CursorMoved", "BufLeave", "WinLeave" }, {
    once = true,
    callback = function()
      if api.nvim_win_is_valid(win) then
        api.nvim_win_close(win, true)
      end
    end,
  })
  return win, float_buf
end

--- Popup the full change description for the line under the cursor.
--- Resolves the cursor change_id from cached annotate entries (M.fetch) then runs
--- `jj show -r <change_id>` async. `opts.full` toggles message-only vs full diff.
--- @param opts { full?: boolean }?
function M.blame_line(opts)
  opts = opts or {}
  local bufnr = api.nvim_get_current_buf()
  local cache_entry = require("jj-signs.cache").get(bufnr)
  if not cache_entry then
    vim.notify("jj-signs: buffer not attached", vim.log.levels.INFO)
    return
  end

  local lnum     = api.nvim_win_get_cursor(0)[1]
  local filepath = api.nvim_buf_get_name(bufnr)

  M.fetch(bufnr, cache_entry.root, filepath, function(entries)
    local change_id = resolve_change_id(entries, lnum)
    if not change_id then
      vim.notify("jj-signs: no blame for line " .. lnum, vim.log.levels.INFO)
      return
    end

    local cmd = { config.config.jj_cmd }
    if config.config.jj_repo then
      vim.list_extend(cmd, { "--repository", config.config.jj_repo })
    end
    vim.list_extend(cmd, { "show", "-r", change_id, "--color=never" })

    vim.system(cmd, { text = true, cwd = cache_entry.root }, function(result)
      if result.code ~= 0 then
        vim.schedule(function()
          vim.notify("jj-signs: jj show failed for " .. change_id, vim.log.levels.ERROR)
        end)
        return
      end
      vim.schedule(function()
        local lines = build_show_lines(result.stdout, opts.full)
        if #lines == 0 then lines = { "(no description)" } end
        open_float(lines, opts.full and "diff" or nil)
      end)
    end)
  end)
end

--- Open a left-aligned scratch split with per-line `change_id • author • date`,
--- scroll-bound (scrollbind) to the source window. Reuses M.fetch's annotate cache.
function M.blame()
  local src_win = api.nvim_get_current_win()
  local bufnr   = api.nvim_get_current_buf()
  local cache_entry = require("jj-signs.cache").get(bufnr)
  if not cache_entry then
    vim.notify("jj-signs: buffer not attached", vim.log.levels.INFO)
    return
  end

  local filepath = api.nvim_buf_get_name(bufnr)

  M.fetch(bufnr, cache_entry.root, filepath, function(entries)
    if not entries then
      vim.notify("jj-signs: no blame data", vim.log.levels.WARN)
      return
    end
    local lines = format_blame_lines(entries)

    -- fetch may invoke cb synchronously (cache hit) or via vim.schedule; defer
    -- all window mutation so we are always on the main loop.
    vim.schedule(function()
      if not api.nvim_win_is_valid(src_win) then return end

      vim.wo[src_win].scrollbind = true

      api.nvim_set_current_win(src_win)
      vim.cmd("leftabove vsplit")
      local blame_win = api.nvim_get_current_win()
      local blame_buf = api.nvim_create_buf(false, true)
      api.nvim_win_set_buf(blame_win, blame_buf)
      api.nvim_buf_set_lines(blame_buf, 0, -1, false, lines)
      vim.bo[blame_buf].modifiable = false
      vim.bo[blame_buf].buftype    = "nofile"
      vim.bo[blame_buf].bufhidden  = "wipe"
      pcall(api.nvim_buf_set_name, blame_buf, "jj-blame://" .. vim.fn.fnamemodify(filepath, ":t"))

      local width = 0
      for _, l in ipairs(lines) do
        width = math.max(width, #l)
      end
      api.nvim_win_set_width(blame_win, math.min(math.max(width + 1, 20), 60))

      vim.wo[blame_win].scrollbind     = true
      vim.wo[blame_win].wrap           = false
      vim.wo[blame_win].number         = false
      vim.wo[blame_win].relativenumber = false
      vim.wo[blame_win].cursorbind     = true
      vim.wo[src_win].cursorbind       = true

      vim.cmd("syncbind")
      vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = blame_buf, silent = true, desc = "Close jj blame" })
    end)
  end)
end

M._parse_annotate    = parse_annotate
M._relative_date     = relative_date
M._format_blame      = format_blame
M._resolve_change_id = resolve_change_id
M._build_show_lines  = build_show_lines
M._format_blame_lines = format_blame_lines

function M.setup_autocmds(augroup)
	local timers = {}

	local function cancel(bufnr)
		local t = timers[bufnr]
		if t then t:stop(); t:close(); timers[bufnr] = nil end
	end

	api.nvim_create_autocmd("CursorMoved", {
		group    = augroup,
		callback = function(args)
			M.clear(args.buf)
			cancel(args.buf)
		end,
	})

	api.nvim_create_autocmd("CursorHold", {
		group    = augroup,
		callback = function(args)
			local bufnr = args.buf
			if not api.nvim_buf_is_valid(bufnr) then return end
			if vim.bo[bufnr].buftype ~= "" then return end

			local cache_entry = require("jj-signs.cache").get(bufnr)
			if not cache_entry then return end

			local lnum     = api.nvim_win_get_cursor(0)[1]
			local filepath = api.nvim_buf_get_name(bufnr)

			local delay = config.config.current_line_blame_opts.delay or 1000
			local timer = (vim.uv or vim.loop).new_timer()
			timers[bufnr] = timer
			timer:start(delay, 0, function()
				cancel(bufnr)
				M.fetch(bufnr, cache_entry.root, filepath, function(entries)
					if entries then
						M.show(bufnr, lnum)
					end
				end)
			end)
		end,
	})
end

return M
