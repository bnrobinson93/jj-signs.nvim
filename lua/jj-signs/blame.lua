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
