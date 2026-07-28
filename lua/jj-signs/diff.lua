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
		elseif #current.removed.lines > 0 then
			-- Pure deletion. Diffs are computed with ctxlen = 0, so the header's
			-- new_start already encodes the deletion anchor — the new-file line
			-- directly above the removed block (0 => top-of-file delete). Just
			-- collapse the added range to that anchor.
			current.added.count = 0
			current.vend = current.added.start
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

return M
