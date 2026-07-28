--- The jj subprocess adapter: the single seam between jj-signs and the `jj` CLI.
--- Every jj invocation in the plugin routes through here, so command construction
--- (the jj_cmd binary, the optional --repository escape hatch) and the
--- side-effect-free read invariant live in one place. Callers ask for data
--- (change_id, parent ids, base text, annotate output); they never build commands.

local config = require("jj-signs.config")

local M = {}

--- Build a jj command, prepending --repository when jj_repo is configured.
--- JJ workspaces are automatically detected via cwd; jj_repo is an escape hatch
--- for files opened outside their workspace (symlinks, remote mounts, etc.).
---
--- IMPORTANT: the metadata reads below (get_change_id, get_parent_ids, fetch_base)
--- all pass `--ignore-working-copy`. Without it, jj auto-snapshots the working
--- copy on each command, writing a new operation to `.jj/repo/op_heads/heads/`.
--- The op-log watcher fires on that write and schedules a refresh, which runs
--- another jj command, which snapshots again — an endless spawn loop (constant
--- `jj log`/`jj diff` churn even on an idle, clean buffer; colocated git repos
--- mint a fresh op every cycle). `--ignore-working-copy` makes these reads
--- side-effect-free. Live edits are diffed via vim.diff against cached base text,
--- so suppressing the implicit snapshot costs no accuracy. The on-demand commands
--- (file_show, annotate, show) omit the flag deliberately: they run only in
--- response to a user action, not on the refresh hot path.
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

--- Run a jj command in `cwd` and hand the result to `cb` on the main loop.
--- @param args string[]
--- @param cwd string
--- @param cb fun(result: vim.SystemCompleted)
local function run(args, cwd, cb)
	vim.system(jj(args), { text = true, cwd = cwd }, function(result)
		vim.schedule(function() cb(result) end)
	end)
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
--- @param cb fun(change_id: string?, bookmark: string?, description: string?)  bookmark/description are "" when absent
function M.get_change_id(root, cb)
	local template = 'change_id ++ "\n" ++ bookmarks ++ "\n" ++ description.first_line()'
	run(
		{ "log", "-r", "@", "-T", template, "--no-graph", "--color=never", "--ignore-working-copy" },
		root,
		function(result)
			local id, bookmark, description = nil, nil, nil
			if result.code == 0 then
				-- Line 1 = change_id, line 2 = space-separated bookmarks (may be
				-- absent), line 3 = description first line (empty for a new change).
				local lines = vim.split(result.stdout, "\n", { plain = true })
				id = vim.trim(lines[1] or "")
				local first = vim.split(vim.trim(lines[2] or ""), "%s+", { trimempty = true })[1]
				bookmark = first or ""
				description = vim.trim(lines[3] or "")
			end
			cb(id, bookmark, description)
		end
	)
end

--- @param root string
--- @param rev string  revision to resolve as the comparison base (e.g. "@-")
--- @param cb fun(parent_change_id: string?, parent_commit_id: string?)
function M.get_parent_ids(root, rev, cb)
	run(
		{ "log", "-r", rev, "-T", 'change_id ++ " " ++ commit_id', "--no-graph", "--color=never", "--ignore-working-copy" },
		root,
		function(result)
			if result.code ~= 0 or not result.stdout then
				cb(nil, nil)
				return
			end
			local parts = vim.split(vim.trim(result.stdout), "%s+", { trimempty = true })
			cb(parts[1], parts[2])
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
	run(
		{ "file", "show", "-r", rev, "--ignore-working-copy", "--", filepath },
		root,
		function(result)
			cb(result.code == 0 and result.stdout or "")
		end
	)
end

--- Show a file's content at `rev` (working-copy-aware, for the diffthis split).
--- @param root string
--- @param rev string
--- @param filepath string
--- @param cb fun(stdout: string?)  nil when the command fails
function M.file_show(root, rev, filepath, cb)
	run(
		{ "file", "show", "--revision", rev, "--", filepath },
		root,
		function(result)
			cb(result.code == 0 and result.stdout or nil)
		end
	)
end

--- Line-by-line blame for a file (`jj annotate`).
--- @param root string
--- @param filepath string
--- @param cb fun(stdout: string?)  nil when the command fails
function M.annotate(root, filepath, cb)
	run(
		{ "annotate", "--color=never", "--", filepath },
		root,
		function(result)
			cb(result.code == 0 and result.stdout or nil)
		end
	)
end

--- Show a single change (`jj show -r <rev>`) for the blame popup.
--- @param root string
--- @param rev string
--- @param cb fun(stdout: string?)  nil when the command fails
function M.show(root, rev, cb)
	run(
		{ "show", "-r", rev, "--color=never" },
		root,
		function(result)
			cb(result.code == 0 and result.stdout or nil)
		end
	)
end

return M
