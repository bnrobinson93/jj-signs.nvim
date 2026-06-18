local config = require("jj-signs.config")

--- @alias JJSigns.HunkType "add" | "change" | "delete" | "topdelete" | "changedelete" | "conflict"

--- @class JJSigns.HunkNode
--- @field start integer
--- @field count integer
--- @field lines string[]

--- @class JJSigns.Hunk
--- @field type    JJSigns.HunkType
--- @field head    string
--- @field added   JJSigns.HunkNode
--- @field removed JJSigns.HunkNode
--- @field vend    integer

local M = {}

--- Build a jj command, prepending --repository when jj_repo is configured.
--- JJ workspaces are automatically detected via cwd; jj_repo is an escape hatch
--- for files opened outside their workspace (symlinks, remote mounts, etc.).
--- @param args string[]
--- @return string[]
local function jj(args)
	local cmd = { config.config.jj_cmd }
	if config.config.jj_repo then
		vim.list_extend(cmd, { "--repository", config.config.jj_repo })
	end
	vim.list_extend(cmd, args)
	return cmd
end

-- root cache keyed by directory path.
-- false  = checked, not a JJ repo
-- string = checked, is a JJ repo (workspace root)
-- nil    = not yet checked
local root_cache = {}

--- @param filepath string
--- @param cb fun(root: string?)
function M.get_root(filepath, cb)
	local dir = vim.fn.fnamemodify(filepath, ":h")

	local cached = root_cache[dir]
	if cached ~= nil then
		-- false means "confirmed not a JJ repo" — pass nil to caller
		cb(cached ~= false and cached or nil)
		return
	end

	vim.system(jj({ "root" }), { text = true, cwd = dir }, function(result)
		local root = result.code == 0 and vim.trim(result.stdout) or false
		root_cache[dir] = root
		vim.schedule(function()
			cb(root ~= false and root or nil)
		end)
	end)
end

--- Clear the root cache (e.g. after a jj workspace add).
function M.clear_root_cache()
	root_cache = {}
end

--- @param root string
--- @param cb fun(change_id: string?)
function M.get_change_id(root, cb)
	vim.system(
		jj({ "log", "-r", "@", "-T", "change_id", "--no-graph", "--color=never" }),
		{ text = true, cwd = root },
		function(result)
			local id = nil
			if result.code == 0 then
				id = vim.trim(result.stdout)
			end
			vim.schedule(function()
				cb(id)
			end)
		end
	)
end

--- @param filepath string
--- @param root string
--- @param cb fun(hunks: JJSigns.Hunk[]?)
function M.run_diff(filepath, root, cb)
	vim.system(
		jj({ "diff", "--git", "--color=never", "-r", "@", "--", filepath }),
		{ text = true, cwd = root },
		function(result)
			if result.code ~= 0 then
				vim.schedule(function()
					cb(nil)
				end)
				return
			end
			local hunks = M.parse_hunks(result.stdout)
			vim.schedule(function()
				cb(hunks)
			end)
		end
	)
end

--- Adapted from gitsigns.nvim (lewis6991/gitsigns.nvim) — MIT License
--- @param line string
--- @return JJSigns.Hunk
function M.parse_diff_line(line)
	local diffkey = vim.trim(vim.split(line, "@@", { plain = true })[2])

	local p = vim.tbl_map(function(s)
		return vim.split(s:sub(2), ",")
	end, vim.split(diffkey, " "))

	local pre, now = p[1], p[2]

	local old_start = tonumber(pre[1]) --[[@as integer]]
	local old_count = tonumber(pre[2]) or 1
	local new_start = tonumber(now[1]) --[[@as integer]]
	local new_count = tonumber(now[2]) or 1

	--- @type JJSigns.Hunk
	local hunk = {
		removed = { start = old_start, count = old_count, lines = {} },
		added = { start = new_start, count = new_count, lines = {} },
		head = line,
		vend = new_start + math.max(new_count - 1, 0),
		type = new_count == 0 and "delete" or old_count == 0 and "add" or "change",
	}
	return hunk
end

--- @param diff_output string
--- @return JJSigns.Hunk[]
function M.parse_hunks(diff_output)
	if not diff_output or diff_output == "" then
		return {}
	end

	local hunks = {} --- @type JJSigns.Hunk[]
	local current = nil --- @type JJSigns.Hunk?

	for _, line in ipairs(vim.split(diff_output, "\n")) do
		if vim.startswith(line, "@@") then
			if current then
				hunks[#hunks + 1] = current
			end
			current = M.parse_diff_line(line)
		elseif current then
			local c = line:sub(1, 1)
			if c == "+" then
				current.added.lines[#current.added.lines + 1] = line:sub(2)
			elseif c == "-" then
				current.removed.lines[#current.removed.lines + 1] = line:sub(2)
			end
		end
	end

	if current then
		hunks[#hunks + 1] = current
	end

	return hunks
end

--- Scan buffer lines for JJ conflict markers and return conflict hunks.
--- JJ conflicts use: <<<<<<< Conflict N of M
--- @param bufnr integer
--- @return JJSigns.Hunk[]
function M.find_conflicts(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local conflict_hunks = {} --- @type JJSigns.Hunk[]
	local in_conflict = false
	local start_lnum = 0

	for i, line in ipairs(lines) do
		if line:match("^<<<<<<< Conflict") then
			in_conflict = true
			start_lnum = i
		elseif line:match("^>>>>>>> Conflict") and in_conflict then
			in_conflict = false
			local count = i - start_lnum + 1
			conflict_hunks[#conflict_hunks + 1] = {
				type = "conflict",
				head = "conflict",
				added = { start = start_lnum, count = count, lines = {} },
				removed = { start = start_lnum, count = count, lines = {} },
				vend = i,
			}
		end
	end

	return conflict_hunks
end

--- Merge diff hunks and conflict hunks, with conflicts taking priority.
--- @param diff_hunks JJSigns.Hunk[]
--- @param conflict_hunks JJSigns.Hunk[]
--- @return JJSigns.Hunk[]
function M.merge_hunks(diff_hunks, conflict_hunks)
	if #conflict_hunks == 0 then
		return diff_hunks
	end

	-- Build a set of lines covered by conflicts
	local conflict_lines = {} --- @type table<integer, boolean>
	for _, ch in ipairs(conflict_hunks) do
		for l = ch.added.start, ch.vend do
			conflict_lines[l] = true
		end
	end

	-- Filter diff hunks that overlap with conflicts
	local result = {} --- @type JJSigns.Hunk[]
	for _, h in ipairs(diff_hunks) do
		local overlaps = false
		for l = h.added.start, h.vend do
			if conflict_lines[l] then
				overlaps = true
				break
			end
		end
		if not overlaps then
			result[#result + 1] = h
		end
	end

	-- Append conflict hunks
	for _, ch in ipairs(conflict_hunks) do
		result[#result + 1] = ch
	end

	-- Sort by start line
	table.sort(result, function(a, b)
		return a.added.start < b.added.start
	end)

	return result
end

return M
