--- Conflict detection: a pipeline distinct from diff parsing. Where diff.lua
--- reads `vim.diff` output, this module reads the buffer directly, scanning for
--- jj's conflict-marker fences and classifying the regions between them. The two
--- meet only at merge_hunks, which folds conflict hunks over the diff hunks.

local M = {}

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
--- Matches the start/end fence of every jj conflict-marker style (diff, snapshot,
--- git): all use a 7-character `<<<<<<<` / `>>>>>>>` fence followed by a space and
--- a label. The diff/snapshot label is "conflict N of M"; the git (diff3) style
--- instead carries a commit id, so we key on the fence, not the label.
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
		if line:sub(1, 8) == "<<<<<<< " then
			in_conflict = true
			start_lnum = lnum
		elseif line:sub(1, 8) == ">>>>>>> " and in_conflict then
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

--- @alias JJSigns.ConflictRole "marker" | "ours" | "theirs" | "base"

--- Classify the lines of a single conflict block into highlightable regions,
--- covering all three jj marker styles (diff, snapshot, git diff3) with one state
--- machine. Returns one entry per line that should be highlighted; context lines
--- shared by both sides (diff-style ` ` lines) are omitted (role left to the
--- buffer's normal highlighting).
---
--- jj merges are N-sided, so there is no intrinsic "ours"/"theirs" — we map the
--- topmost side to `ours`, the bottommost to `theirs`, the merge base to `base`,
--- and any middle sides to `ours` (matching git's diff3 top=ours convention).
---
--- Marker/fence/separator lines (`<<<<<<<`, `%%%%%%%`, `+++++++`, `-------`,
--- `|||||||`, `=======`, `>>>>>>>`) are tagged `marker`.
---
--- @param lines string[]  the block's lines, lines[1] = the `<<<<<<<` fence
--- @param offset integer?  1-based buffer lnum of lines[1] (default 1)
--- @return { lnum: integer, role: JJSigns.ConflictRole }[]
function M.parse_conflict_regions(lines, offset)
	offset = offset or 1
	local markers = {} --- @type { lnum: integer }[]
	local base_lnums = {} --- @type integer[]
	local sides = {} --- @type integer[][]  one bucket of lnums per side, in order
	local cur_side = nil --- @type integer[]?  bucket receiving plain body lines
	local cur_base = false           -- plain body lines go to base
	local in_diff = false            -- inside a `%%%%%%%` diff section

	local function new_side()
		cur_side = {}
		cur_base = false
		in_diff = false
		sides[#sides + 1] = cur_side
		return cur_side
	end

	for i, line in ipairs(lines) do
		local lnum = offset + i - 1
		local h8 = line:sub(1, 8)
		if h8 == "<<<<<<< " then
			markers[#markers + 1] = { lnum = lnum }
			new_side() -- git-style "ours" body (if any) lands here; dropped if empty
		elseif h8 == ">>>>>>> " then
			markers[#markers + 1] = { lnum = lnum }
			cur_side, cur_base, in_diff = nil, false, false
		elseif h8 == "%%%%%%% " then
			markers[#markers + 1] = { lnum = lnum }
			new_side() -- the diff's `+` lines form this side
			in_diff = true
		elseif line:sub(1, 7) == "\\\\\\\\\\\\\\" then
			-- second line of the diff-style `%%%%%%%` header ("\\\\\\\ to: ...")
			markers[#markers + 1] = { lnum = lnum }
		elseif h8 == "+++++++ " then
			markers[#markers + 1] = { lnum = lnum }
			new_side() -- snapshot side: literal body lines
		elseif h8 == "------- " or line:sub(1, 7) == "|||||||" then
			markers[#markers + 1] = { lnum = lnum }
			cur_side, cur_base, in_diff = nil, true, false
		elseif line == "=======" then
			markers[#markers + 1] = { lnum = lnum }
			new_side() -- git-style "theirs" body
		else
			if in_diff then
				local c = line:sub(1, 1)
				if c == "+" then
					cur_side[#cur_side + 1] = lnum
				elseif c == "-" then
					base_lnums[#base_lnums + 1] = lnum
				end
				-- context (` `) is shared; leave unhighlighted
			elseif cur_side then
				cur_side[#cur_side + 1] = lnum
			elseif cur_base then
				base_lnums[#base_lnums + 1] = lnum
			end
		end
	end

	-- Drop empty side buckets (e.g. the placeholder opened by the start fence in
	-- diff/snapshot styles), then map first→ours, last→theirs, middle→ours.
	local non_empty = {}
	for _, b in ipairs(sides) do
		if #b > 0 then non_empty[#non_empty + 1] = b end
	end

	local regions = {} --- @type { lnum: integer, role: JJSigns.ConflictRole }[]
	for _, m in ipairs(markers) do
		regions[#regions + 1] = { lnum = m.lnum, role = "marker" }
	end
	for _, l in ipairs(base_lnums) do
		regions[#regions + 1] = { lnum = l, role = "base" }
	end
	for idx, bucket in ipairs(non_empty) do
		local role = (idx == #non_empty and #non_empty > 1) and "theirs" or "ours"
		for _, l in ipairs(bucket) do
			regions[#regions + 1] = { lnum = l, role = role }
		end
	end

	table.sort(regions, function(a, b) return a.lnum < b.lnum end)
	return regions
end

--- Conflict scan with the cheap guard folded in: returns find_conflicts hunks
--- when the region holds a conflict-start marker, else `{}` (skipping the fuller
--- scan). `first`/`last` are 0-indexed (as passed to nvim_buf_get_lines); omit
--- both to scan the whole buffer.
--- @param bufnr integer
--- @param first integer?  0-indexed start line (default 0)
--- @param last integer?   0-indexed end line, exclusive (default -1 = end)
--- @return JJSigns.Hunk[]
function M.scan_conflicts(bufnr, first, last)
	if not M.has_conflict_marker(bufnr, first, last) then
		return {}
	end
	return M.find_conflicts(bufnr, first, last)
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
