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
--- @param rev string  revision to resolve as the comparison base (e.g. "@-")
--- @param cb fun(parent_change_id: string?, parent_commit_id: string?)
function M.get_parent_ids(root, rev, cb)
	vim.system(
		jj({ "log", "-r", rev, "-T", 'change_id ++ " " ++ commit_id', "--no-graph", "--color=never" }),
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

--- Fetch the comparison-base revision's content for a file.
--- Returns empty string for new files not yet in that revision.
--- @param filepath string
--- @param root string
--- @param rev string  revision whose file content is the comparison base
--- @param cb fun(base_text: string)
function M.fetch_base(filepath, root, rev, cb)
	vim.system(
		jj({ "file", "show", "-r", rev, "--", filepath }),
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
--- @param rev string  comparison base revision ("@-" = default @ vs its parent)
--- @param cb fun(hunks: JJSigns.Hunk[]?)
function M.run_diff(filepath, root, rev, cb)
	-- Default base (@-) maps to `jj diff -r @` (working copy vs its parent) — kept
	-- byte-for-byte. A non-default base needs an explicit from/to range so the
	-- hunks reflect that revision rather than the parent.
	local args = (rev == "@-")
		and { "diff", "--git", "--color=never", "-r", "@", "--", filepath }
		or  { "diff", "--git", "--color=never", "--from", rev, "--to", "@", "--", filepath }
	vim.system(
		jj(args),
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

--- Build a vim.diff() opts table from config.diff_opts merged with `extra`.
--- `extra` supplies call-specific fields (result_type, ctxlen); it wins on
--- conflict. vim.diff exposes whitespace handling as native boolean opts
--- (:h vim.diff) — ignore_whitespace = iwhiteall, ignore_whitespace_change =
--- iwhite at the xdiff level — so the config keys pass straight through.
--- linematch is only set when truthy so vim.diff keeps its default off-state.
--- @param extra table?
--- @return table
function M.build_diff_opts(extra)
	local d = config.config.diff_opts or {}
	local o = {
		algorithm        = d.algorithm or "myers",
		indent_heuristic = d.indent_heuristic or false,
	}
	if d.linematch then o.linematch = d.linematch end
	if d.ignore_whitespace then o.ignore_whitespace = true end
	if d.ignore_whitespace_change then o.ignore_whitespace_change = true end
	if extra then
		for k, v in pairs(extra) do o[k] = v end
	end
	return o
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

	-- Merge config diff_opts on the main thread, then serialize into primitives
	-- for the worker (only primitives cross the new_work boundary — no tables).
	local merged = M.build_diff_opts({ result_type = "unified", ctxlen = tonumber(opts.ctxlen) or 3 })

	local work = uv.new_work(
		function(a, b, ctxlen, algorithm, indent_heuristic, linematch, iwc, iw)
			-- Worker thread: no access to upvalues/closures/vim state.
			if type(vim) ~= "table" or type(vim.diff) ~= "function" then
				return "__no_diff__", ""
			end
			-- Rebuild the opts table from the primitives that crossed the boundary.
			local o = {
				result_type      = "unified",
				ctxlen           = tonumber(ctxlen) or 3,
				algorithm        = algorithm,
				indent_heuristic = indent_heuristic,
			}
			if linematch and linematch > 0 then o.linematch = linematch end
			if iwc then o.ignore_whitespace_change = true end
			if iw then o.ignore_whitespace = true end
			local ok, result = pcall(vim.diff, a, b, o)
			if not ok then
				return "__no_diff__", ""
			end
			return "ok", result or ""
		end,
		function(status, result)
			if status ~= "ok" then
				-- Worker lacks a usable vim.diff (older Neovim): run it on the
				-- main thread instead, with the same merged opts.
				vim.schedule(function()
					local ok, r = pcall(vim.diff, base_text, buf_text, merged)
					cb((ok and r and r ~= "") and r or nil)
				end)
				return
			end
			vim.schedule(function()
				cb(result ~= "" and result or nil)
			end)
		end
	)
	work:queue(
		base_text,
		buf_text,
		merged.ctxlen,
		merged.algorithm,
		merged.indent_heuristic and true or false,
		merged.linematch or 0,
		merged.ignore_whitespace_change and true or false,
		merged.ignore_whitespace and true or false
	)
end

--- Cheap guard: does a buffer region contain a conflict-start marker? A single
--- pass with a prefix compare (no regex, no table allocation) that bails on the
--- first hit, so callers can skip the fuller find_conflicts scan + merge when no
--- conflict can possibly be present. `first`/`last` are 0-indexed (as passed to
--- nvim_buf_get_lines); omit both to scan the whole buffer.
--- @param bufnr integer
--- @param first integer?  0-indexed start line (default 0)
--- @param last integer?   0-indexed end line, exclusive (default -1 = end)
--- @return boolean
function M.has_conflict_marker(bufnr, first, last)
	local lines = vim.api.nvim_buf_get_lines(bufnr, first or 0, last or -1, false)
	for _, line in ipairs(lines) do
		if line:sub(1, 7) == "<<<<<<<" then return true end
	end
	return false
end

--- Scan buffer lines for JJ conflict markers and return conflict hunks.
--- JJ conflicts use: <<<<<<< Conflict N of M
--- `first`/`last` narrow the scan to a 0-indexed line range (as passed to
--- nvim_buf_get_lines); omit both to scan the whole buffer. Returned hunk line
--- numbers are 1-based buffer lines regardless of the slice offset.
--- @param bufnr integer
--- @param first integer?  0-indexed start line (default 0)
--- @param last integer?   0-indexed end line, exclusive (default -1 = end)
--- @return JJSigns.Hunk[]
function M.find_conflicts(bufnr, first, last)
	local offset = first or 0
	local lines = vim.api.nvim_buf_get_lines(bufnr, offset, last or -1, false)
	local conflict_hunks = {} --- @type JJSigns.Hunk[]
	local in_conflict = false
	local start_lnum = 0

	for i, line in ipairs(lines) do
		local lnum = offset + i  -- 1-based buffer line
		if line:match("^<<<<<<< Conflict") then
			in_conflict = true
			start_lnum = lnum
		elseif line:match("^>>>>>>> Conflict") and in_conflict then
			in_conflict = false
			local count = lnum - start_lnum + 1
			conflict_hunks[#conflict_hunks + 1] = {
				type = "conflict",
				head = "conflict",
				added = { start = start_lnum, count = count, lines = {} },
				removed = { start = start_lnum, count = count, lines = {} },
				vend = lnum,
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
