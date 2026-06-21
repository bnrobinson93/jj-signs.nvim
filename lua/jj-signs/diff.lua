local config = require("jj-signs.config")

--- @alias JJSigns.HunkType "add" | "change" | "delete" | "topdelete" | "changedelete" | "conflict"

--- @class JJSigns.HunkNode
--- @field start integer
--- @field count integer
--- @field lines string[]
--- @field lnums integer[]  exact line numbers (1-based) for each entry in `lines`

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

--- @param root string
--- @param cb fun(parent_change_id: string?, parent_commit_id: string?)
function M.get_parent_ids(root, cb)
	vim.system(
		jj({ "log", "-r", "@-", "-T", 'change_id ++ " " ++ commit_id', "--no-graph", "--color=never" }),
		{ text = true, cwd = root },
		function(result)
			if result.code ~= 0 or not result.stdout then
				vim.schedule(function() cb(nil, nil) end)
				return
			end
			local parts = vim.split(vim.trim(result.stdout), "%s+", { trimempty = true })
			vim.schedule(function() cb(parts[1], parts[2]) end)
		end
	)
end

--- Fetch the parent revision's content for a file.
--- Returns empty string for new files not yet in the parent.
--- @param filepath string
--- @param root string
--- @param cb fun(base_text: string)
function M.fetch_base(filepath, root, cb)
	vim.system(
		jj({ "file", "show", "-r", "@-", "--", filepath }),
		{ text = true, cwd = root },
		function(result)
			local base = result.code == 0 and result.stdout or ""
			vim.schedule(function()
				cb(base)
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
		removed = { start = old_start, count = old_count, lines = {}, lnums = {} },
		added = { start = new_start, count = new_count, lines = {}, lnums = {} },
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
	local new_line = 0
	local first_added = nil --- @type integer?
	local last_added = nil --- @type integer?

	local function finalize()
		if not current then return end
		current.removed.count = #current.removed.lines
		if first_added ~= nil then
			current.added.start = first_added
			current.vend = last_added --[[@as integer]]
			current.added.count = #current.added.lines
		end
		if #current.added.lines == 0 then
			current.type = "delete"
		elseif #current.removed.lines == 0 then
			current.type = "add"
		else
			current.type = "change"
		end
		hunks[#hunks + 1] = current
	end

	for _, line in ipairs(vim.split(diff_output, "\n")) do
		if vim.startswith(line, "@@") then
			finalize()
			current = M.parse_diff_line(line)
			new_line = current.added.start
			first_added = nil
			last_added = nil
		elseif current then
			local c = line:sub(1, 1)
			if c == "+" then
				if not first_added then first_added = new_line end
				last_added = new_line
				current.added.lines[#current.added.lines + 1] = line:sub(2)
				current.added.lnums[#current.added.lnums + 1] = new_line
				new_line = new_line + 1
			elseif c == "-" then
				current.removed.lines[#current.removed.lines + 1] = line:sub(2)
			elseif c == " " then
				new_line = new_line + 1
			end
		end
	end

	finalize()

	return hunks
end

--- Run vim.diff() off the main thread via the libuv thread pool.
---
--- uv.new_work(work_fn, after_fn) runs work_fn in a thread-pool worker with a
--- fresh Lua VM: it cannot see upvalues, closures, or Neovim state. vim.diff()
--- is a pure xdiff C call with no editor-state access, so it IS safe to call
--- from a worker on Neovim 0.10+.
---
--- Fallback: on older builds vim.diff may be missing inside the worker. The
--- worker detects this (or any pcall error) and signals "__no_diff__" back; the
--- after_fn then runs vim.diff synchronously on the main thread via vim.schedule.
---
--- @param base_text string
--- @param buf_text  string
--- @param opts      table   same opts table passed to vim.diff() (ctxlen used)
--- @param cb        fun(result: string?)
function M.diff_async(base_text, buf_text, opts, cb)
	local uv = vim.uv or vim.loop

	local work = uv.new_work(
		function(a, b, opts_str)
			-- Worker thread: no access to upvalues/closures/vim state.
			if type(vim) ~= "table" or type(vim.diff) ~= "function" then
				return "__no_diff__", ""
			end
			-- Only ctxlen crosses the thread boundary (primitives only).
			local o = { result_type = "unified", ctxlen = tonumber(opts_str) or 3 }
			local ok, result = pcall(vim.diff, a, b, o)
			if not ok then
				return "__no_diff__", ""
			end
			return "ok", result or ""
		end,
		function(status, result)
			if status ~= "ok" then
				-- Worker lacks a usable vim.diff (older Neovim): run it on the
				-- main thread instead.
				vim.schedule(function()
					local o = { result_type = "unified", ctxlen = tonumber(opts.ctxlen) or 3 }
					local ok, r = pcall(vim.diff, base_text, buf_text, o)
					cb((ok and r and r ~= "") and r or nil)
				end)
				return
			end
			vim.schedule(function()
				cb(result ~= "" and result or nil)
			end)
		end
	)
	work:queue(base_text, buf_text, tostring(opts.ctxlen or 3))
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

--- Merge freshly-computed partial hunks (from a narrowed diff over a dirty line
--- range) into a cached full-buffer hunk list. Hunks that overlap the dirty
--- range are stale and dropped; non-overlapping hunks are kept untouched. The
--- partial hunks replace the dropped region.
---
--- Ranges are line numbers; existing hunks span [added.start, vend].
--- @param existing JJSigns.Hunk[]
--- @param new_partial JJSigns.Hunk[]
--- @param range_first integer  start of dirty range
--- @param range_last  integer  end of dirty range
--- @return JJSigns.Hunk[]
function M.replace_hunks_in_range(existing, new_partial, range_first, range_last)
	local result = {} --- @type JJSigns.Hunk[]

	-- Keep cached hunks that lie entirely outside the dirty range.
	for _, h in ipairs(existing or {}) do
		if h.vend < range_first or h.added.start > range_last then
			result[#result + 1] = h
		end
	end

	-- Splice in the freshly-diffed hunks for the dirty region.
	for _, h in ipairs(new_partial or {}) do
		result[#result + 1] = h
	end

	table.sort(result, function(a, b)
		return a.added.start < b.added.start
	end)

	return result
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
