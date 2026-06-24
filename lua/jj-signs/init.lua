local api = vim.api

local config     = require("jj-signs.config")
local cache      = require("jj-signs.cache")
local base_cache = require("jj-signs.base_cache")
local async    = require("jj-signs.async")
local diff_mod = require("jj-signs.diff")
local signs    = require("jj-signs.signs")
local hunks    = require("jj-signs.hunks")
local autocmds = require("jj-signs.autocmds")
local watcher  = require("jj-signs.watcher")
local status   = require("jj-signs.status")

local M = {}

--- Global on/off flag. When false, auto-attach (via schedule_refresh) is
--- skipped. Toggled by M.enable / M.disable; read by autocmds.schedule_refresh.
M._enabled = true

--- Bump every known root's op generation so the next refresh re-reads @'s
--- change_id. Called on repo-internal writes that may have changed the op. The
--- op-generation state lives in the watcher module (single canonical instance);
--- see watcher.lua for why init.lua can't own it.
function M.invalidate_op_state()
  watcher.invalidate()
end

--- @param opts JJSigns.Config?
function M.setup(opts)
  config.setup(opts)
  M._initialized = true

  -- Register the :JJSigns command (also registered in plugin/ pre-setup).
  require("jj-signs.cli").create_command()

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
  map("n", "<leader>ghp", function() M.preview_hunk()        end, "Preview JJ hunk")
  map("n", "<leader>ghP", function() M.preview_hunk_inline() end, "Preview JJ hunk (inline)")
  map("n", "<leader>ghr", function() M.restore_hunk()    end, "Restore JJ hunk from @-")
  map("n", "<leader>ghd", function() M.diffthis()        end, "Diff this vs @-")
  map("n", "<leader>ghD", function() M.diffthis_rev()    end, "Diff this vs revision…")
  map("n", "<leader>ghb", function() M.blame_line({ full = true }) end, "Blame line (popup)")
  map("n", "<leader>ghB", function() M.blame()           end, "Blame full file")
  map({"x", "o"}, "ih",  function() M.select_hunk(bufnr) end, "Select JJ hunk")
  map("n", "<leader>ghq", function() M.setqflist("attached", { open = true }) end, "JJ hunks → quickfix")
  map("n", "<leader>ghl", function() M.setloclist(0, { open = true })        end, "JJ hunks → loclist")
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
      base_rev    = "@-",
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
      -- A new op landed (the watcher already bumped its generation). Invalidate
      -- buffer caches and schedule refreshes; refresh() re-reads @'s change_id.
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
  status.clear(bufnr)
  cache.clear(bufnr)

  -- Evict shared base_cache entries no longer referenced by any live buffer.
  local active_keys = {}
  for buf, ent in pairs(cache.all()) do
    if ent.parent_change_id and ent.parent_commit_id then
      local fp = api.nvim_buf_get_name(buf)
      active_keys[base_cache.key(fp, ent.parent_change_id, ent.parent_commit_id, ent.base_rev)] = true
    end
  end
  base_cache.evict_stale(active_keys)

  if entry then
    watcher.stop(entry.root)
  end
end

local unpack = table.unpack or _G.unpack  -- LuaJIT exposes the global form

--- Suspend the running coroutine until `starter`'s callback fires, returning the
--- callback's arguments. Production async primitives invoke their callback on a
--- later tick (vim.system + vim.schedule, or the libuv thread pool), so the
--- coroutine is suspended on the yield by the time they resume it. Tests, though,
--- stub these to call back synchronously — before the yield — so this also
--- handles the callback firing within `starter` itself: results are captured and
--- returned without yielding at all.
--- @param starter fun(resume: fun(...))
--- @return any ...
local function await(starter)
  local co = assert(coroutine.running(), "jj-signs await: not in a coroutine")
  local results   --- @type table?
  local yielded = false
  starter(function(...)
    results = { n = select("#", ...), ... }
    -- Only resume if we actually suspended; a synchronous callback fires before
    -- the yield below, so there is nothing to resume — we fall through instead.
    if yielded and coroutine.status(co) == "suspended" then
      coroutine.resume(co)
    end
  end)
  if results == nil then
    yielded = true
    coroutine.yield()
  end
  return unpack(results, 1, results.n)
end

--- Diff the (modified) buffer against cached base content and place signs.
--- Coroutine-style: yields on the off-thread vim.diff and resumes to paint.
--- @param bufnr integer
--- @param base_text string
local function do_buf_diff(bufnr, base_text)
  if not api.nvim_buf_is_valid(bufnr) then return end
  local e = cache.get(bufnr)
  if not e then return end

  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local buf_text = table.concat(lines, "\n")
  if vim.bo[bufnr].eol then buf_text = buf_text .. "\n" end

  -- With a narrow dirty range, diff only that region (±3 context lines for
  -- correct hunk boundaries) and merge the partial result into cached hunks.
  local dr = e.dirty_range
  if dr then
    local ctx = 3
    local first = math.max(0, dr.first - ctx)
    local last  = math.min(#lines, dr.last + ctx)
    local base_lines = vim.split(base_text, "\n")
    local base_narrow = table.concat(vim.list_slice(base_lines, first + 1, last), "\n") .. "\n"
    local buf_narrow  = table.concat(vim.list_slice(lines, first + 1, last), "\n") .. "\n"

    local diff_out = await(function(resume)
      diff_mod.diff_async(base_narrow, buf_narrow, { ctxlen = ctx }, resume)
    end)
    if not api.nvim_buf_is_valid(bufnr) then return end
    local e2 = cache.get(bufnr)
    if not e2 then return end

    -- Adjust hunk line numbers by the slice offset
    local partial = (diff_out and diff_out ~= "") and diff_mod.parse_hunks(diff_out) or {}
    for _, hk in ipairs(partial) do
      hk.added.start   = hk.added.start   + first
      hk.vend          = hk.vend          + first
      hk.removed.start = hk.removed.start + first
      if hk.added.lnums then
        for i, l in ipairs(hk.added.lnums) do
          hk.added.lnums[i] = l + first
        end
      end
    end

    -- Conflict rescan limited to the dirty range (no whole-buffer scan per
    -- keystroke), expanded to cover any cached conflict the edit overlaps so a
    -- multi-line marker starting outside the range is not lost.
    local cfirst, clast = dr.first, dr.last
    for _, hk in ipairs(e2.hunks) do
      if hk.type == "conflict"
        and (hk.added.start - 1) <= dr.last and (hk.vend - 1) >= dr.first
      then
        cfirst = math.min(cfirst, hk.added.start - 1)
        clast  = math.max(clast, hk.vend - 1)
      end
    end
    local merged_hunks = diff_mod.replace_hunks_in_range(e2.hunks, partial, dr.first, dr.last)
    local conflict_hunks = diff_mod.scan_conflicts(bufnr, cfirst, clast + 1)
    local merged = diff_mod.merge_hunks(merged_hunks, conflict_hunks)
    e2.hunks = merged
    e2.dirty = false
    e2.dirty_range = nil
    signs.place(bufnr, merged)
    status.update(bufnr, merged, e2.change_id)
  else
    -- Full diff fallback (first load or unknown range)
    local diff_out = await(function(resume)
      diff_mod.diff_async(base_text, buf_text, { ctxlen = 3 }, resume)
    end)
    if not api.nvim_buf_is_valid(bufnr) then return end
    local diff_hunks = (diff_out and diff_out ~= "") and diff_mod.parse_hunks(diff_out) or {}
    local conflict_hunks = diff_mod.scan_conflicts(bufnr)
    local merged = diff_mod.merge_hunks(diff_hunks, conflict_hunks)
    local e2 = cache.get(bufnr)
    if not e2 then return end
    e2.hunks = merged
    e2.dirty = false
    e2.dirty_range = nil
    signs.place(bufnr, merged)
    status.update(bufnr, merged, e2.change_id)
  end
end

--- Coroutine body of M.refresh. Runs the full refresh pipeline with `await`
--- between async steps, so it stays suspended (not returned) until all work
--- completes. That is what lets the throttle (async.throttle_async) serialize a
--- burst: `running[bufnr]` stays set across the awaits, collapsing intervening
--- calls into a single trailing refresh instead of fanning out subprocesses.
---
--- Both saved and unsaved buffers diff the live buffer content against cached
--- base text via vim.diff (off-thread). No `jj diff` runs, so the working copy is
--- never snapshotted and the op log is never touched — which is what keeps the
--- watcher from re-firing in a loop. The only jj reads are metadata (`jj log`
--- change_id + parent ids) and a single `jj file show` to seat the base text,
--- all `--ignore-working-copy`.
--- @param bufnr integer
local function refresh_impl(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then return end

  local filepath = api.nvim_buf_get_name(bufnr)
  if filepath == "" then return end

  if not cache.has(bufnr) then
    M.attach(bufnr)
    return
  end

  local entry = cache.get(bufnr)
  if not entry then return end

  local base_rev = entry.base_rev or "@-"

  -- Read @'s change_id to detect when the working-copy commit moved (jj new,
  -- edit, abandon, …). Gated by the op-log watcher: when no operation landed
  -- since the last read, reuse the cached id and skip the `jj log` subprocess.
  local gen = watcher.op_gen(entry.root)
  local new_change_id = watcher.cached_change_id(entry.root)
  if not new_change_id then
    new_change_id = await(function(resume)
      diff_mod.get_change_id(entry.root, resume)
    end)
  end
  if not new_change_id then return end
  entry = cache.get(bufnr)
  if not entry then return end

  -- Stamp the read with the generation it was issued at. If the watcher bumped
  -- the generation while the subprocess ran, this stamp is already stale and the
  -- next refresh re-reads — the new op can't be lost.
  watcher.record_change_id(entry.root, new_change_id, gen)

  -- Resolve the comparison-base parent ids only when the op generation moved
  -- since they were last resolved (or no base content is cached). Parent ids
  -- change only when an operation lands, so this gate avoids a `jj log` per edit.
  if not (entry.base_text and entry.parent_gen == gen) then
    local new_pcid, new_ppid = await(function(resume)
      diff_mod.get_parent_ids(entry.root, base_rev, resume)
    end)
    entry = cache.get(bufnr)
    if not entry then return end
    if new_pcid ~= entry.parent_change_id or new_ppid ~= entry.parent_commit_id then
      entry.base_text        = nil
      entry.parent_change_id = new_pcid
      entry.parent_commit_id = new_ppid
    end
    entry.parent_gen = gen
  end

  -- Ensure base content (the file as of base_rev) is cached: local entry, shared
  -- base_cache, then a single `jj file show` scoped to this file. This is the
  -- only jj read that touches file content.
  if not entry.base_text then
    local cached_base = base_cache.get(filepath, entry.parent_change_id, entry.parent_commit_id, base_rev)
    if cached_base then
      entry.base_text = cached_base
    else
      local base_text = await(function(resume)
        diff_mod.fetch_base(filepath, entry.root, base_rev, resume)
      end)
      entry = cache.get(bufnr)
      if not entry then return end
      entry.base_text = base_text
      base_cache.set(filepath, entry.parent_change_id, entry.parent_commit_id, base_text, base_rev)
    end
  end

  -- Skip the diff when nothing relevant changed since the last successful one:
  -- buffer unmodified, no pending dirty range, no cache invalidation, and @'s
  -- change_id unchanged. Keeps repeat BufEnter / FocusGained cheap (no diff, no
  -- subprocess — all jj reads above were already served from cache).
  if not vim.bo[bufnr].modified
    and not entry.dirty
    and entry.dirty_range == nil
    and new_change_id == entry.change_id
    and entry.hunks ~= nil
  then
    return
  end

  -- Diff the buffer against the cached base via vim.diff (off-thread). do_buf_diff
  -- handles both the narrow (dirty_range) and full cases and places the signs.
  do_buf_diff(bufnr, entry.base_text)

  entry = cache.get(bufnr)
  if entry then
    entry.change_id = new_change_id
    entry.dirty     = false
    local stat = (vim.uv or vim.loop).fs_stat(filepath)
    entry.mtime = stat and stat.mtime.sec or 0
  end
end

--- The coroutine body, exposed for the throttled auto-refresh path only. The
--- throttle (async.throttle_async) already runs its callback inside a coroutine
--- it owns; calling this inline there lets the `await`s suspend *that* coroutine,
--- which is what serializes a burst. Do NOT call this from anywhere else — a bare
--- `coroutine.running()` is not necessarily the throttle's (plenary runs each test
--- in its own coroutine, other plugins may too), and yielding someone else's
--- coroutine on an await that never resolves would deadlock it. Public callers use
--- M.refresh, which always spins a dedicated coroutine.
M._refresh_impl = refresh_impl

--- Refresh signs for a buffer. The live buffer content is diffed against cached
--- base text (the file as of base_rev) via vim.diff, so signs update without a
--- write and without snapshotting the working copy.
---
--- Always runs the pipeline in its own coroutine (via async.run) so the `await`s
--- never suspend the caller. The throttled auto-refresh path is the one exception
--- and uses M._refresh_impl directly inside the throttle's own coroutine.
--- @param bufnr integer?
function M.refresh(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  async.run(refresh_impl, bufnr)
end

--- Point a buffer's comparison base at `rev` and force a refresh. Invalidates the
--- cached base content and resolved parent ids so the next refresh re-fetches the
--- file as it exists in `rev`. base_rev defaults to "@-" (parent of @); change_base
--- is the per-buffer escape hatch for "what changed since <rev>" (e.g. a branch point).
--- @param entry JJSigns.CacheEntry
--- @param bufnr integer
--- @param rev string
local function apply_base(bufnr, entry, rev)
  entry.base_rev         = rev
  entry.base_text        = nil
  entry.parent_change_id = nil
  entry.parent_commit_id = nil
  entry.dirty            = true
  entry.dirty_range      = nil
  M.refresh(bufnr)
end

--- Compare a buffer against `rev` instead of the default parent (@-).
--- @param rev string  revision to use as the comparison base
--- @param bufnr integer?  target buffer; defaults to current
function M.change_base(rev, bufnr)
  if not rev or rev == "" then
    vim.notify("jj-signs: change_base requires a revision", vim.log.levels.WARN)
    return
  end
  bufnr = bufnr or api.nvim_get_current_buf()
  local entry = cache.get(bufnr)
  if not entry then return end
  apply_base(bufnr, entry, rev)
end

--- Restore the default comparison base (@-) for a buffer.
--- @param bufnr integer?  target buffer; defaults to current
function M.reset_base(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local entry = cache.get(bufnr)
  if not entry then return end
  apply_base(bufnr, entry, "@-")
end

--- Read-only accessor: a copy of the cached hunks for a buffer. Returns an empty
--- table when the buffer is not attached, so callers never see nil.
--- @param bufnr integer?
--- @return JJSigns.Hunk[]
function M.get_hunks(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local entry = cache.get(bufnr)
  if not entry or not entry.hunks then return {} end
  return vim.deepcopy(entry.hunks)
end

--- Whether jj-signs is attached to a buffer.
--- @param bufnr integer?
--- @return boolean
function M.is_attached(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  return cache.has(bufnr)
end

--- Detach from every attached buffer.
function M.detach_all()
  -- Snapshot keys first: M.detach mutates the cache table as we go.
  local bufs = {}
  for bufnr in pairs(cache.all()) do
    bufs[#bufs + 1] = bufnr
  end
  for _, bufnr in ipairs(bufs) do
    M.detach(bufnr)
  end
end

--- Schedule a refresh for every attached, visible buffer.
function M.refresh_all()
  for bufnr in pairs(cache.all()) do
    if api.nvim_buf_is_valid(bufnr) and #vim.fn.win_findbuf(bufnr) > 0 then
      autocmds.schedule_refresh(bufnr)
    end
  end
end

--- Globally disable jj-signs: detach all buffers and skip auto-attach until
--- M.enable is called.
function M.disable()
  M._enabled = false
  M.detach_all()
end

--- Globally (re-)enable jj-signs and attach to all currently loaded buffers.
function M.enable()
  M._enabled = true
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(bufnr) then
      M.attach(bufnr)
    end
  end
end

--- @param direction "next" | "prev" | "first" | "last"
--- @param opts? { wrap?: boolean, preview?: boolean|"inline", foldopen?: boolean, count?: integer, navigation_message?: boolean }
function M.nav_hunk(direction, opts)
  hunks.nav_hunk(direction, opts)
end

function M.preview_hunk()
  hunks.preview_hunk()
end

--- Inline (virtual-line) preview of the hunk under cursor; no floating window.
function M.preview_hunk_inline()
  hunks.preview_hunk_inline()
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

--- Popup the full change description for the cursor line. Additive to (and
--- independent of) the inline `current_line_blame` EOL virtual text.
--- @param opts { full?: boolean }|string|nil  CLI passes "full" as a string
function M.blame_line(opts)
  if type(opts) == "string" then
    opts = { full = (opts == "full" or opts == "true") }
  end
  require("jj-signs.blame").blame_line(opts)
end

--- Open a scroll-bound side split blaming the whole file.
function M.blame()
  require("jj-signs.blame").blame()
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

--- Populate the quickfix list with hunks across buffers. Drives list-based
--- navigation and Trouble.nvim. Reads cached hunks only — no jj subprocess.
--- @param target "attached"|integer|string|nil  "attached"/nil = all attached
---   buffers, 0 = current buffer, otherwise a specific bufnr
--- @param opts { open?: boolean, use_loc?: boolean }?
function M.setqflist(target, opts)
  require("jj-signs.qflist").setqflist(target, opts)
end

--- Populate the current window's location list with hunks.
--- @param target "attached"|integer|string|nil  defaults to 0 (current buffer)
--- @param opts { open?: boolean }?
function M.setloclist(target, opts)
  require("jj-signs.qflist").setloclist(target, opts)
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

--- Re-place signs for every attached buffer from its cached hunks. signs.place
--- re-reads the live config flags (signcolumn/numhl/linehl/word_diff/show_deleted)
--- on each call, so a single reapply propagates any flag flip to all buffers.
function M._reapply_all()
  for bufnr, entry in pairs(cache.all()) do
    if api.nvim_buf_is_valid(bufnr) and entry.hunks then
      signs.place(bufnr, entry.hunks)
    end
  end
end

--- Flip a boolean config flag, or set it to an explicit value when given.
--- @param flag string  key in config.config
--- @param value boolean?  explicit value; nil toggles the current value
--- @return boolean  the new value
local function set_flag(flag, value)
  if value == nil then value = not config.config[flag] end
  config.config[flag] = value
  return value
end

--- Toggle the sign column. Mirrors gitsigns' toggle_signs.
--- @param value boolean?  explicit value; nil toggles
--- @return boolean  the new signcolumn state
function M.toggle_signs(value)
  local v = set_flag("signcolumn", value)
  M._reapply_all()
  return v
end

--- Toggle number-column highlighting. Forces the non-provider extmark path.
--- @param value boolean?  explicit value; nil toggles
--- @return boolean  the new numhl state
function M.toggle_numhl(value)
  local v = set_flag("numhl", value)
  M._reapply_all()
  return v
end

--- Toggle line highlighting. Forces the non-provider extmark path.
--- @param value boolean?  explicit value; nil toggles
--- @return boolean  the new linehl state
function M.toggle_linehl(value)
  local v = set_flag("linehl", value)
  M._reapply_all()
  return v
end

--- Toggle inline word-diff highlighting. signs.place gates place_word_diff.
--- @param value boolean?  explicit value; nil toggles
--- @return boolean  the new word_diff state
function M.toggle_word_diff(value)
  local v = set_flag("word_diff", value)
  M._reapply_all()
  return v
end

--- Toggle virtual-line display of deleted lines. signs.place gates the rendering.
--- @param value boolean?  explicit value; nil toggles
--- @return boolean  the new show_deleted state
function M.toggle_deleted(value)
  local v = set_flag("show_deleted", value)
  M._reapply_all()
  return v
end

return M
