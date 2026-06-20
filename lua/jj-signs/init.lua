local api = vim.api

local config     = require("jj-signs.config")
local cache      = require("jj-signs.cache")
local base_cache = require("jj-signs.base_cache")
local diff_mod = require("jj-signs.diff")
local signs    = require("jj-signs.signs")
local hunks    = require("jj-signs.hunks")
local autocmds = require("jj-signs.autocmds")
local watcher  = require("jj-signs.watcher")

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
      root        = root,
      change_id   = "",
      mtime       = 0,
      hunks       = {},
      dirty       = true,
      dirty_range = nil,
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

    -- Track dirty line ranges per keystroke instead of re-diffing the whole
    -- buffer on every TextChanged. on_lines reports the changed line region;
    -- we union it into entry.dirty_range so refresh() can narrow the diff.
    api.nvim_buf_attach(bufnr, false, {
      on_lines = function(_, buf, _, first, _last_old, last_new, _)
        local e = cache.get(buf)
        if not e then return true end  -- return true to detach
        -- Union new dirty range with existing dirty range
        if not e.dirty_range then
          e.dirty_range = { first = first, last = last_new }
        else
          e.dirty_range.first = math.min(e.dirty_range.first, first)
          e.dirty_range.last  = math.max(e.dirty_range.last, last_new)
        end
        autocmds.schedule_refresh(buf)
      end,
    })

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
  autocmds.cancel(bufnr)
  signs.clear(bufnr)
  cache.clear(bufnr)

  -- Evict shared base_cache entries no longer referenced by any live buffer.
  local active_keys = {}
  for buf, ent in pairs(cache.all()) do
    if ent.parent_change_id and ent.parent_commit_id then
      local fp = api.nvim_buf_get_name(buf)
      active_keys[base_cache.key(fp, ent.parent_change_id, ent.parent_commit_id)] = true
    end
  end
  base_cache.evict_stale(active_keys)

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

  -- Unsaved buffer: diff buffer content directly against cached parent so signs
  -- update live. Parent content is fetched once and cached in entry.base_text;
  -- subsequent TextChanged events run vim.diff() synchronously with no subprocess.
  if vim.bo[bufnr].modified then
    local function do_buf_diff(base_text)
      if not api.nvim_buf_is_valid(bufnr) then return end

      local e = cache.get(bufnr)
      local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local buf_text = table.concat(lines, "\n")
      if vim.bo[bufnr].eol then buf_text = buf_text .. "\n" end

      -- If we have a narrow dirty range, diff only that region.
      -- Context lines (±3) ensure hunk boundaries are correct.
      -- On narrow diff: produce a partial result and merge into cached hunks.
      local dr = e and e.dirty_range
      local use_narrow = dr ~= nil and e ~= nil and #e.hunks >= 0

      if use_narrow then
        local ctx = 3
        local first = math.max(0, dr.first - ctx)
        local last  = math.min(#lines, dr.last + ctx)
        local base_lines = vim.split(base_text, "\n")
        local base_narrow = table.concat(vim.list_slice(base_lines, first + 1, last), "\n") .. "\n"
        local buf_narrow  = table.concat(vim.list_slice(lines, first + 1, last), "\n") .. "\n"

        diff_mod.diff_async(base_narrow, buf_narrow, { ctxlen = ctx }, function(diff_out)
          if not api.nvim_buf_is_valid(bufnr) then return end
          local e2 = cache.get(bufnr)
          if not e2 then return end
          -- Adjust hunk line numbers by the slice offset
          local partial = (diff_out and diff_out ~= "") and diff_mod.parse_hunks(diff_out) or {}
          for _, hk in ipairs(partial) do
            hk.added.start   = hk.added.start   + first
            hk.vend          = hk.vend          + first
            hk.removed.start = hk.removed.start + first
          end
          -- Merge partial hunks into cached hunk list: replace hunks that overlap
          -- the dirty range; keep others unchanged.
          local merged_hunks = diff_mod.replace_hunks_in_range(e2.hunks, partial, dr.first, dr.last)
          local conflict_hunks = diff_mod.find_conflicts(bufnr)
          local merged = diff_mod.merge_hunks(merged_hunks, conflict_hunks)
          e2.hunks = merged
          e2.dirty = false
          e2.dirty_range = nil
          signs.place(bufnr, merged)
        end)
      else
        -- Full diff fallback (first load or unknown range)
        diff_mod.diff_async(base_text, buf_text, { ctxlen = 3 }, function(diff_out)
          if not api.nvim_buf_is_valid(bufnr) then return end
          local diff_hunks = (diff_out and diff_out ~= "") and diff_mod.parse_hunks(diff_out) or {}
          local conflict_hunks = diff_mod.find_conflicts(bufnr)
          local merged = diff_mod.merge_hunks(diff_hunks, conflict_hunks)
          local e2 = cache.get(bufnr)
          if not e2 then return end
          e2.hunks = merged
          e2.dirty = false
          e2.dirty_range = nil
          signs.place(bufnr, merged)
        end)
      end
    end

    diff_mod.get_parent_ids(entry.root, function(new_pcid, new_ppid)
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
        local cached_base = base_cache.get(filepath, new_pcid, new_ppid)
        if cached_base then
          e.base_text = cached_base   -- keep local entry in sync
          do_buf_diff(cached_base)
        else
          diff_mod.fetch_base(filepath, e.root, function(base_text)
            local e2 = cache.get(bufnr)
            if not e2 then return end
            e2.base_text = base_text
            e2.parent_change_id = new_pcid
            e2.parent_commit_id = new_ppid
            base_cache.set(filepath, new_pcid, new_ppid, base_text)
            do_buf_diff(base_text)
          end)
        end
      end
    end)
    return
  end

  diff_mod.get_change_id(entry.root, function(new_change_id)
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
        dirty_range      = nil,  -- file clean after write
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
