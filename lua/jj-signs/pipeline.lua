--- The refresh pipeline: the coroutine-driven path that turns a buffer's live
--- content into placed signs. It owns the async orchestration (await between jj
--- reads and the off-thread diff), the per-buffer diff serialization, and the
--- op-generation / base-content caching gates. init.lua drives it via M.refresh;
--- the throttled auto-refresh path (autocmds) calls M._refresh_impl directly.

local api = vim.api

local cache      = require("jj-signs.cache")
local base_cache = require("jj-signs.base_cache")
local jj         = require("jj-signs.jj")
local diff_mod   = require("jj-signs.diff")
local conflict   = require("jj-signs.conflict")
local signs      = require("jj-signs.signs")
local status     = require("jj-signs.status")
local watcher    = require("jj-signs.watcher")
local async      = require("jj-signs.async")

local M = {}

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
local function do_buf_diff(bufnr, base_text, change_id)
  if not api.nvim_buf_is_valid(bufnr) then return end
  local e = cache.get(bufnr)
  if not e then return end

  -- Serialize diffs per buffer. Refreshes reach here from several uncoordinated
  -- coroutines (throttled auto-refresh, M.refresh on attach/change_base, the
  -- op-log watcher) and vim.diff runs off the main thread, so two of them can
  -- otherwise have diffs in flight for the same buffer at once — wasted work
  -- plus a last-writer race on the placed signs. The throttle only serializes
  -- its own path; this guard covers all of them. If a diff is already running,
  -- record that another pass is wanted and bail; the in-flight diff re-runs once
  -- it finishes, against the then-current buffer content.
  if e.diffing then
    e.diff_pending = true
    return
  end
  e.diffing = true

  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local buf_text = table.concat(lines, "\n")
  if vim.bo[bufnr].eol then buf_text = buf_text .. "\n" end

  -- Normalize base line endings to the buffer's. nvim_buf_get_lines strips line
  -- terminators, so buf_text is always LF-joined, but `jj file show` returns the
  -- committed bytes verbatim — CRLF for a dos file, CR for a mac file. Without
  -- this, every line of a non-unix file reads as changed. Match gitsigns: fold
  -- the base to LF for the comparison (the cached/shared base_text stays raw).
  local ff = vim.bo[bufnr].fileformat
  if ff == "dos" then
    base_text = (base_text:gsub("\r\n", "\n"))
  elseif ff == "mac" then
    base_text = (base_text:gsub("\r", "\n"))
  end

  -- Always diff the whole buffer against the base. A narrow per-keystroke path
  -- (re-diff only the dirty window, merge into cached hunks) was tried but its
  -- base-window mapping was unsound — boundary-spanning hunks could not be
  -- reconstructed from a windowed re-diff, producing duplicate hunks, spurious
  -- add→change flips, and wrong counts (a differential fuzz against the full
  -- diff caught all of these). vim.diff runs off the main thread and refreshes
  -- are throttled, so the whole-buffer diff is cheap enough to be the only path.
  --
  -- ctxlen = 0 keeps each add/change/delete a separate minimal hunk, so an
  -- isolated deletion renders its own delete sign instead of merging into a
  -- nearby change.
  local diff_out = await(function(resume)
    diff_mod.diff_async(base_text, buf_text, { ctxlen = 0 }, resume)
  end)
  if not api.nvim_buf_is_valid(bufnr) then e.diffing = false; return end
  local diff_hunks = (diff_out and diff_out ~= "") and diff_mod.parse_hunks(diff_out) or {}
  local conflict_hunks = conflict.scan_conflicts(bufnr)
  local merged = conflict.merge_hunks(diff_hunks, conflict_hunks)
  local e2 = cache.get(bufnr)
  if not e2 then e.diffing = false; return end
  e2.hunks = merged
  e2.dirty = false
  e2.dirty_range = nil
  signs.place(bufnr, merged)
  -- Use the freshly-read change_id, not e2.change_id: on the first refresh after
  -- attach the cached field is still "" (it is committed later, after this runs),
  -- which would blank the statusline head. Fall back to the cached value when a
  -- caller omits it.
  status.update(bufnr, merged, change_id or e2.change_id, e2.bookmark, e2.description)

  -- Release the per-buffer diff lock. If a refresh arrived while this diff ran,
  -- run one more pass against the now-current buffer content (coalesced: a burst
  -- collapses to a single trailing diff, never an overlapping one).
  e2.diffing = false
  if e2.diff_pending then
    e2.diff_pending = false
    if e2.base_text then do_buf_diff(bufnr, e2.base_text, change_id) end
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
    require("jj-signs").attach(bufnr)
    return
  end

  local entry = cache.get(bufnr)
  if not entry then return end

  local base_rev = entry.base_rev or "@-"

  -- Read @'s change_id to detect when the working-copy commit moved (jj new,
  -- edit, abandon, …). Gated by the op-log watcher: when no operation landed
  -- since the last read, reuse the cached id and skip the `jj log` subprocess.
  local gen = watcher.op_gen(entry.root)
  local new_change_id, new_bookmark, new_description = watcher.cached_change_id(entry.root)
  if not new_change_id then
    new_change_id, new_bookmark, new_description = await(function(resume)
      jj.get_change_id(entry.root, resume)
    end)
  end
  if not new_change_id then return end
  entry = cache.get(bufnr)
  if not entry then return end
  entry.bookmark = new_bookmark or ""
  entry.description = new_description or ""

  -- Stamp the read with the generation it was issued at. If the watcher bumped
  -- the generation while the subprocess ran, this stamp is already stale and the
  -- next refresh re-reads — the new op can't be lost.
  watcher.record_change_id(entry.root, new_change_id, gen, entry.bookmark, entry.description)

  -- Resolve the comparison-base parent ids only when the op generation moved
  -- since they were last resolved (or no base content is cached). Parent ids
  -- change only when an operation lands, so this gate avoids a `jj log` per edit.
  if not (entry.base_text and entry.parent_gen == gen) then
    local new_pcid, new_ppid = await(function(resume)
      jj.get_parent_ids(entry.root, base_rev, resume)
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
        jj.fetch_base(filepath, entry.root, base_rev, resume)
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
    -- Hunks are still valid (change_id unchanged), but the bookmark or
    -- description may have moved without moving change_id (e.g. `jj bookmark
    -- set`, `jj describe`), so keep the statusline dict in sync before bailing.
    status.update(bufnr, entry.hunks, new_change_id, entry.bookmark, entry.description)
    return
  end

  -- Diff the whole buffer against the cached base via vim.diff (off-thread) and
  -- place the signs.
  do_buf_diff(bufnr, entry.base_text, new_change_id)

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

return M
