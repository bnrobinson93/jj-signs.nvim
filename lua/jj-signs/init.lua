local api = vim.api

local config   = require("jj-signs.config")
local cache    = require("jj-signs.cache")
local diff_mod = require("jj-signs.diff")
local signs    = require("jj-signs.signs")
local hunks    = require("jj-signs.hunks")
local autocmds = require("jj-signs.autocmds")
local watcher  = require("jj-signs.watcher")

-- Generation counter per buffer. Incremented on every refresh() call so that
-- in-flight async callbacks from earlier calls can detect they are stale and
-- abort instead of clobbering fresher results.
local refresh_gens = {} --- @type table<integer, integer>

local M = {}

--- @param opts JJSigns.Config?
function M.setup(opts)
  config.setup(opts)

  if vim.fn.executable(config.config.jj_cmd) == 0 then
    vim.notify("jj-signs: '" .. config.config.jj_cmd .. "' not found in PATH", vim.log.levels.WARN)
    return
  end

  signs.setup_highlights()
  signs.setup()
  autocmds.setup()
end

--- Default buffer-local keymaps, applied when on_attach is nil.
--- Mirrors LazyVim's gitsigns keymap layout so muscle memory transfers.
--- @param bufnr integer
local function default_keymaps(bufnr)
  local function map(mode, key, fn, desc)
    vim.keymap.set(mode, key, fn, { buffer = bufnr, desc = desc, silent = true })
  end

  map("n", "]h",          function() M.nav_hunk("next")  end, "Next JJ hunk")
  map("n", "[h",          function() M.nav_hunk("prev")  end, "Prev JJ hunk")
  map("n", "]H",          function() M.nav_hunk("last")  end, "Last JJ hunk")
  map("n", "[H",          function() M.nav_hunk("first") end, "First JJ hunk")
  map("n", "<leader>ghp", function() M.preview_hunk()    end, "Preview JJ hunk")
  map("n", "<leader>ghr", function() M.restore_hunk()    end, "Restore JJ hunk from @-")
  map("n", "<leader>ghd", function() M.diffthis()        end, "Diff this vs @-")
  map("n", "<leader>ghD", function() M.diffthis_rev()    end, "Diff this vs revision…")
  map({"x", "o"}, "ih",  function() M.select_hunk(bufnr) end, "Select JJ hunk")
end

--- Attach to a buffer: detect jj repo, seed cache, apply keymaps, kick off first refresh.
--- @param bufnr integer?
function M.attach(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  if cache.has(bufnr) then return end

  local filepath = api.nvim_buf_get_name(bufnr)
  if filepath == "" then return end

  diff_mod.get_root(filepath, function(root)
    if not root then return end  -- not a jj repo

    cache.set(bufnr, {
      root      = root,
      change_id = "",
      mtime     = 0,
      hunks     = {},
      dirty     = true,
    })

    -- Apply keymaps: user-supplied on_attach, or built-in defaults
    local on_attach = config.config.on_attach
    if on_attach then
      if on_attach(bufnr) == false then
        cache.clear(bufnr)
        return
      end
    else
      default_keymaps(bufnr)
    end

    M.refresh(bufnr)

    watcher.start(root, function()
      cache.invalidate_all_in_root(root)
      for buf, buf_entry in pairs(cache.all()) do
        if buf_entry.root == root then
          autocmds.schedule_refresh(buf)
        end
      end
    end)
  end)
end

--- @param bufnr integer?
function M.detach(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local entry = cache.get(bufnr)
  refresh_gens[bufnr] = nil
  autocmds.cancel(bufnr)
  signs.clear(bufnr)
  cache.clear(bufnr)
  if entry then
    watcher.stop(entry.root)
  end
end

--- Refresh signs for a buffer. Checks change_id + mtime cache before running jj diff.
--- When the buffer has unsaved changes, diffs buffer content directly so signs
--- update live without requiring a write.
--- @param bufnr integer?
function M.refresh(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()

  if not api.nvim_buf_is_valid(bufnr) then return end

  local filepath = api.nvim_buf_get_name(bufnr)
  if filepath == "" then return end

  if not cache.has(bufnr) then
    M.attach(bufnr)
    return
  end

  local entry = cache.get(bufnr)
  if not entry then return end

  -- Bump generation so any in-flight callbacks from a prior refresh abort.
  local gen = (refresh_gens[bufnr] or 0) + 1
  refresh_gens[bufnr] = gen

  -- Unsaved buffer: diff buffer content directly against cached parent so signs
  -- update live. Parent content is fetched once and cached in entry.base_text;
  -- subsequent TextChanged events run vim.diff() synchronously with no subprocess.
  if vim.bo[bufnr].modified then
    local function do_buf_diff(base_text)
      if refresh_gens[bufnr] ~= gen then return end  -- stale
      if not api.nvim_buf_is_valid(bufnr) then return end
      local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buf_text = table.concat(lines, "\n")
      if vim.bo[bufnr].eol then buf_text = buf_text .. "\n" end

      diff_mod.diff_async(base_text, buf_text, { ctxlen = 3 }, function(diff_out)
        -- Generation check INSIDE the callback (post-thread): stale callbacks
        -- from a prior refresh must abort after the worker returns, not only
        -- before dispatch. The check at the top of do_buf_diff is an early-exit.
        if refresh_gens[bufnr] ~= gen then return end
        if not api.nvim_buf_is_valid(bufnr) then return end
        local diff_hunks = (diff_out and diff_out ~= "") and diff_mod.parse_hunks(diff_out) or {}
        local conflict_hunks = diff_mod.find_conflicts(bufnr)
        local merged = diff_mod.merge_hunks(diff_hunks, conflict_hunks)
        local e = cache.get(bufnr)
        if not e then return end
        e.hunks = merged
        e.dirty = false
        signs.place(bufnr, merged)
      end)
    end

    diff_mod.get_parent_ids(entry.root, function(new_pcid, new_ppid)
      if refresh_gens[bufnr] ~= gen then return end  -- stale
      local e = cache.get(bufnr)
      if not e then return end

      if new_pcid ~= e.parent_change_id or new_ppid ~= e.parent_commit_id then
        e.base_text = nil
        e.parent_change_id = new_pcid
        e.parent_commit_id = new_ppid
      end

      if e.base_text then
        do_buf_diff(e.base_text)
      else
        diff_mod.fetch_base(filepath, e.root, function(base_text)
          if refresh_gens[bufnr] ~= gen then return end  -- stale
          local e2 = cache.get(bufnr)
          if not e2 then return end
          e2.base_text = base_text
          e2.parent_change_id = new_pcid
          e2.parent_commit_id = new_ppid
          do_buf_diff(base_text)
        end)
      end
    end)
    return
  end

  diff_mod.get_change_id(entry.root, function(new_change_id)
    if refresh_gens[bufnr] ~= gen then return end
    if not new_change_id then return end

    local stat = (vim.uv or vim.loop).fs_stat(filepath)
    local new_mtime = stat and stat.mtime.sec or 0

    -- Fast path: parent unchanged and we have base_text.
    -- The file on disk == buffer content we already diffed, so jj diff would
    -- return the same hunks. Mutate mtime in place and skip the subprocess.
    if entry.base_text and new_change_id == entry.change_id then
      entry.mtime     = new_mtime
      entry.dirty     = false
      entry.change_id = new_change_id
      return
    end

    if not entry.dirty
      and new_change_id == entry.change_id
      and new_mtime == entry.mtime
    then
      return
    end

    diff_mod.run_diff(filepath, entry.root, function(diff_hunks)
      if refresh_gens[bufnr] ~= gen then return end
      if not diff_hunks then
        signs.clear(bufnr)
        return
      end
      if not api.nvim_buf_is_valid(bufnr) then return end
      local conflict_hunks = diff_mod.find_conflicts(bufnr)
      local merged = diff_mod.merge_hunks(diff_hunks, conflict_hunks)
      cache.set(bufnr, {
        root             = entry.root,
        change_id        = new_change_id,
        mtime            = new_mtime,
        hunks            = merged,
        dirty            = false,
        base_text        = entry.base_text,
        parent_change_id = entry.parent_change_id,
        parent_commit_id = entry.parent_commit_id,
      })
      signs.place(bufnr, merged)
    end)
  end)
end

--- @param direction "next" | "prev" | "first" | "last"
function M.nav_hunk(direction)
  hunks.nav_hunk(direction)
end

function M.preview_hunk()
  hunks.preview_hunk()
end

function M.restore_hunk()
  hunks.restore_hunk(api.nvim_get_current_buf())
end

function M.diffthis(rev)
  hunks.diffthis(rev)
end

function M.diffthis_rev()
  hunks.diffthis_rev()
end

--- @param bufnr integer?
function M.select_hunk(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local entry = cache.get(bufnr)
  if not entry or not entry.hunks then return end

  local lnum = api.nvim_win_get_cursor(0)[1]
  local hunk = hunks.find_hunk(lnum, entry.hunks)
  if not hunk then return end

  local first = math.max(1, hunk.added.start)
  local last  = first + math.max(hunk.added.count, 1) - 1

  vim.cmd("normal! " .. first .. "GV" .. last .. "G")
end

--- Summary for statusline components.
--- @return { added: integer, changed: integer, deleted: integer, conflicts: integer }
function M.summary()
  local bufnr = api.nvim_get_current_buf()
  local entry = cache.get(bufnr)
  if not entry then
    return { added = 0, changed = 0, deleted = 0, conflicts = 0 }
  end
  return hunks.get_summary(entry.hunks)
end

function M.toggle_current_line_blame()
  config.config.current_line_blame = not config.config.current_line_blame
  if not config.config.current_line_blame then
    local blame = require("jj-signs.blame")
    for _, bufnr in ipairs(api.nvim_list_bufs()) do
      blame.clear(bufnr)
    end
  end
end

return M
