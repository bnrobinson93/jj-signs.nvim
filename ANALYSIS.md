# Plugin Analysis: gitsigns.nvim vs jj-signs.nvim

> Source of truth: gitsigns.nvim (GitHub: lewis6991/gitsigns.nvim, local cache: `~/.local/share/nvim/lazy/gitsigns.nvim`)

---

## Part 1: gitsigns.nvim

### Scale

| Metric | Value |
|--------|-------|
| Production LOC | ~9,281 across 51 modules |
| Test LOC | ~7,175 across 15 test files |
| Test-to-code ratio | ~77% |

### Features

**Signs & Visual Decorations**
- Sign column: add `┃`, change `┃`, delete `_`, topdelete `‾`, changedelete `~`, untracked `┆`
- Separate staged signs (`signs_staged`) — shows index vs HEAD independently
- Number column highlighting (`numhl`)
- Full line highlighting (`linehl`)
- Current line under cursor highlighting (`culhl`)
- Word-diff inline character-level highlights (`GitSignsAddLnInline`, `GitSignsChangeLnInline`, `GitSignsDeleteLnInline`)
- Show-deleted virtual lines (inline deleted content above deletion point)
- Modern `statuscolumn` integration via `require('gitsigns').statuscolumn()`

**Hunk Actions**
- Stage hunk / reset hunk (visual or motion range)
- Stage buffer / reset buffer
- Partial hunk staging by visual line selection
- Hunk navigation: next/prev with wrapscan
- Preview hunk inline (extmark-based diff in buffer)
- Preview hunk popup (floating window)
- Hunk text object (`ih`) for operator/visual use
- Restore/undo stage

**Blame**
- Current line blame: virtual EOL text with configurable formatter and position (`eol`, `overlay`, `right_align`)
- Full buffer blame view: separate window with heat-map author timestamps, commit hash, summary
- Blame popup: `blame_line` with optional full detail mode
- Custom `current_line_blame_formatter` and `blame_formatter` hooks
- Heat map: color-codes by author time relative to min/max seen in file

**Diff & Revision**
- `change_base <REV>` to compare against arbitrary revisions (not just HEAD)
- `diffthis [REV]` opens vertical diffsplit
- `show <REV>` opens buffer at specific revision (fugitive protocol integration)
- Algorithm selection: myers, minimal, patience, histogram
- `linematch` for non-contiguous hunk detection

**Integrations**
- Quickfix/location list: `setqflist` / `setloclist` with targets (all, attached, buffer)
- Trouble.nvim: auto-detected, used for qf list
- Statusline: `b:gitsigns_status`, `b:gitsigns_status_dict`, `b:gitsigns_head`
- Fugitive protocol URL parsing for revision comparison buffers
- Custom `User GitSignsUpdate` autocommand event

### Architecture

**Module Structure**

```
gitsigns.lua          -- entry point, metatable delegation
plugin/gitsigns.lua   -- one-liner plugin init

Core:
  manager.lua         -- update orchestration, throttle/debounce per buffer
  attach.lua          -- nvim_buf_attach, autocmd registration, git context
  async.lua           -- coroutine-based async framework (custom, not plenary)
  debounce.lua        -- trailing debounce + async throttle utilities
  cache.lua           -- per-buffer CacheEntry (hunks, blame, compare_text)

Git layer:
  git.lua             -- GitObj: object store reads, file content at revision
  git/repo.lua        -- repository metadata, HEAD OID tracking
  git/repo/watcher.lua -- fs_event + fs_poll for .git dir changes
  git/cmd.lua         -- subprocess execution, locale handling
  git/blame.lua       -- blame log parser
  git/version.lua     -- git binary version detection

Diff:
  diff.lua            -- dispatcher: internal vs external
  diff_int.lua        -- vim.diff() with uv.new_work() thread for large files
  diff_ext.lua        -- git diff via temp files (fallback)

Signs & Rendering:
  signs.lua           -- extmark-based sign placement, highlight caching
  sign_renderer.lua   -- window-level rendering
  render/capture.lua  -- syntax highlight capture from scratch buffers
  render/overlay.lua  -- layer-based extmark rendering with priority
  hunk_preview.lua    -- popup and inline preview

Actions:
  actions.lua         -- public API dispatch
  actions/nav.lua     -- hunk navigation + wrapscan
  actions/preview.lua -- hunk previews
  actions/blame.lua   -- blame window + hash coloring
  actions/diffthis.lua -- diff buffer lifecycle
  actions/qflist.lua  -- qf/location list population

Features:
  current_line_blame.lua -- virtual text blame with debounce + focus check
  word_diff.lua          -- character-level diff with extmark overlays

Support:
  config.lua          -- 976 LOC schema validation + defaults
  highlight.lua       -- fallback chain: GitGutter → Signify → Diff*
  status.lua          -- status string formatting
  util.lua            -- shared helpers
  async.lua           -- coroutine Task system
```

**Neovim Integration Hooks**

| Hook | Purpose |
|------|---------|
| `nvim_buf_attach()` `on_lines` | Incremental change tracking (fires on every edit) |
| `nvim_set_decoration_provider` | `on_win` + `on_line` for lazy per-visible-line rendering |
| BufFilePost, BufRead, BufNewFile, BufWritePost | Attach triggers |
| BufFilePre, VimLeavePre | Detach triggers |
| ColorScheme | Rebuild highlights |
| DirChanged | Update branch info |
| QuickFixCmdPre/Post | Disable attach during vimgrep |
| TabEnter, BufEnter | Trigger deferred window rendering |
| OptionSet | Track `number`, `relativenumber`, `foldtext` changes |

### Test Suite

**Framework**: Neovim's built-in test framework (`nvim-test` module)

**Test files (15 total, ~7,175 LOC)**

| File | What it tests |
|------|---------------|
| `gitsigns_spec.lua` (~42k) | Full integration: signs, blame, word-diff, statusline, preview, navigation, stage/reset, qf list, screen rendering |
| `actions_spec.lua` (~22k) | All action commands; partial hunk staging by line range |
| `word_diff_spec.lua` (~56k) | Character-level diff regions, multi-line pairs |
| `blame_spec.lua` (~18k) | Blame formatting, heat maps, author time, "Not Committed Yet" edge case |
| `gitdir_watcher_spec.lua` (~15k) | fs_event and fs_poll watcher behavior, debounce |
| `git_spec.lua` (~9k) | Git version detection, repo metadata, OID tracking |
| `hunk_spec.lua` (~3k) | Hunk creation, partial hunk logic |
| `debounce_spec.lua` (~4k) | Trailing debounce, per-key hashing, error propagation |
| `qflist_spec.lua` (~3k) | Quickfix and location list population |
| `highlights_spec.lua` (~3k) | Highlight generation, fallback chains |
| `render_capture_spec.lua` (~4k) | Syntax highlight capture |
| `render_virt_spec.lua` (~3k) | Virtual text rendering |
| `git_locale_spec.lua` (~2k) | Git command locale stripping |

**Infrastructure**
- `Screen` class for pixel-perfect terminal rendering assertions
- `setup_test_repo()` creates real temp git repos
- `wait_for_attach()`, `command_wait_gitsigns_update()` for async test gates
- `match_dag()` for DAG-based diff assertions

**Notable gaps**
- No explicit benchmarks for large files
- No chaos/concurrent-edit stress tests
- Windows CRLF edge cases lightly covered
- External diff fallback path undertested

---

## Part 2: jj-signs.nvim

### Scale

| Metric | Value |
|--------|-------|
| Production LOC | ~1,458 across 8 modules |
| Test LOC | ~770 across 5 spec files (+ helpers) |
| Test-to-code ratio | ~53% |

### Features

**Signs & Visual Decorations**
- Sign column: add `▎`, change `▎`, delete `▁`, topdelete `▔`, changedelete `▎`, conflict `╪`
- Number column highlighting (`numhl`, off by default)
- Full line highlighting (`linehl`, off by default)
- Show-deleted virtual lines (capped at 20 lines, `show_deleted` off by default)
- Word-diff inline character-level highlights (`JJSignsChangeWord`, `show_word_diff` off by default)
- Decoration provider (`use_decoration_provider = true`) for lazy sign rendering

**Hunk Actions**
- Hunk navigation: next/prev/first/last with wrapscan
- Preview hunk popup (floating window, auto-close on cursor move)
- Restore hunk (writes `removed.lines` back into buffer, saves)
- Diffthis: vertical diffsplit against `@-` or arbitrary revision via `vim.ui.input`
- Hunk text object (`ih`)

**Blame**
- Current line blame: virtual EOL text on `CursorHold` with configurable delay (default 1000ms)
- Parses `jj annotate` output: change_id, author (from email prefix), date
- Relative date formatting (hours/days/weeks/months/years ago)
- Blame cache keyed by `change_id` — avoids re-fetching when unchanged
- `toggle_current_line_blame()` clears all blame virtual text on disable

**Diff**
- Live unsaved-buffer diff: uses `vim.diff()` against cached `base_text` (no subprocess on `TextChanged`)
- JJ conflict detection: scans for `<<<<<<< Conflict N of M` / `>>>>>>> Conflict N of M` markers
- Conflict merge: conflict hunks override overlapping diff hunks

**Integrations**
- `M.summary()` → `{ added, changed, deleted, conflicts }` for statusline
- `on_attach` callback hook for custom keymaps (return false to cancel attach)
- `jj_repo` config for files opened outside their workspace

### Architecture

**Module Structure**

```
plugin/jj-signs.lua   -- one-liner, lazy-loaded entry

lua/jj-signs/
  init.lua      -- setup(), attach(), detach(), refresh(), public API
  config.lua    -- defaults + deep_extend merge
  diff.lua      -- vim.system jj commands + unified diff parser + conflict detection
  signs.lua     -- extmark placement, decoration provider, deleted-lines virtual text
  hunks.lua     -- nav, preview float, restore, diffthis, get_summary
  autocmds.lua  -- autocmd group, debounce timer table
  cache.lua     -- per-buffer CacheEntry (hunks, change_id, mtime, base_text)
  blame.lua     -- jj annotate runner, parser, virtual text, cache
  word_diff.lua -- vim.diff() character-level regions + extmark placement
```

**Neovim Integration Hooks**

| Hook | Purpose |
|------|---------|
| BufEnter, BufWritePost, FocusGained | Schedule debounced refresh |
| TextChanged, TextChangedI, InsertLeave | Schedule debounced refresh (unsaved diff) |
| ColorScheme | Rebuild highlights |
| BufWritePost `*.jj` | Invalidate all caches (repo-level ops) |
| CursorMoved | Clear blame virtual text |
| CursorHold | Schedule blame fetch after delay |

**Refresh Logic (key design)**

1. Bump generation counter — stale async callbacks detect mismatch and abort
2. If buffer is modified: use `vim.diff()` against cached `base_text` (sync, no subprocess)
3. Otherwise: check `change_id` and `mtime` — if unchanged, skip entirely
4. If changed: `jj diff --git` subprocess → parse → place signs

**Cache Structure**

```lua
CacheEntry = {
  root       : string,    -- workspace root
  change_id  : string,    -- jj @ change_id at last refresh
  mtime      : number,    -- file mtime.sec at last refresh
  hunks      : Hunk[],
  dirty      : boolean,   -- force refresh on next trigger
  hunk_index : table[],   -- sorted [{start, vend, sign_type}] for binary search
  base_text  : string?,   -- parent revision content (nil = not yet fetched)
}
```

### Test Suite

**Framework**: Busted (via `nvim --headless -u minimal_init.lua`)

**Test files (5 spec files, ~770 LOC)**

| File | What it tests |
|------|---------------|
| `diff_spec.lua` (~185 LOC) | `parse_diff_line`, `parse_hunks`, `find_conflicts`, `merge_hunks` |
| `hunks_spec.lua` (~262 LOC) | `find_hunk`, `find_nearest_hunk`, `get_summary`, `restore_hunk` |
| `signs_spec.lua` (~123 LOC) | `build_hunk_index`, `find_sign_at` binary search |
| `blame_spec.lua` (~85 LOC) | `parse_annotate`, `relative_date` |
| `word_diff_spec.lua` (~53 LOC) | `run_word_diff` region detection |

**Coverage approach**: Pure unit tests only. No integration tests, no screen rendering assertions, no subprocess/async behavior tested.

---

## Part 3: Compare and Contrast

### Feature Parity

| Feature | gitsigns | jj-signs | Notes |
|---------|----------|----------|-------|
| Add/change/delete signs | ✅ | ✅ | |
| Topdelete / changedelete | ✅ | ✅ | |
| Conflict signs | — | ✅ | JJ-specific; gitsigns has no equivalent |
| Staged signs | ✅ | — | JJ has no staging area |
| Untracked file signs | ✅ | — | Not yet implemented |
| Word diff | ✅ | ✅ | Both use `vim.diff()` internally |
| Show deleted virtual lines | ✅ | ✅ | jj-signs caps at 20 lines |
| numhl / linehl | ✅ | ✅ | |
| Current line blame (EOL) | ✅ | ✅ | |
| Full buffer blame view | ✅ | — | Significant gap |
| Blame heat map | ✅ | — | |
| Hunk navigation | ✅ | ✅ | |
| Hunk preview popup | ✅ | ✅ | gitsigns also has inline preview |
| Hunk text object | ✅ | ✅ | |
| Stage/unstage hunk | ✅ | — | No staging in JJ |
| Restore hunk | ✅ | ✅ | |
| Partial hunk stage | ✅ | — | |
| Diffthis | ✅ | ✅ | |
| Change base revision | ✅ | partial | jj-signs only via `diffthis_rev` |
| Quickfix/location list | ✅ | — | |
| Statusline integration | ✅ | ✅ | gitsigns has named buffer vars |
| Decoration provider | ✅ | ✅ | |
| statuscolumn support | ✅ | — | |
| `on_attach` hook | ✅ | ✅ | |
| Arbitrary revision compare | ✅ | ✅ | |

---

### Performance: Deep Comparison

This is where gitsigns is most mature. Specific gaps in jj-signs:

#### 1. Async Architecture

**gitsigns**: Custom coroutine-based async system (`async.lua`, 691 LOC). Every async operation is a `Task` with `.await()`, structured cancellation, and error propagation. The update path is fully non-blocking:

```
on_lines callback → throttle_async → async Task → uv.new_work (diff) → schedule → render
```

**jj-signs**: Simpler. Uses `vim.system()` callbacks directly (which are async), plus `vim.schedule()` to return to main thread. No coroutine framework. This is fine for the current feature set but makes complex async coordination (e.g., cancelling mid-flight when a newer request arrives) harder.

**Gap**: jj-signs uses a generation counter (`refresh_gens`) to discard stale callbacks — this works but is manual. gitsigns' `throttle_async` handles this structurally, ensuring only one diff per buffer runs at a time with queued re-run if a request was missed.

#### 2. Diff Computation: Worker Threads

**gitsigns**: For large files, `diff_int.lua` offloads `vim.diff()` to a `uv.new_work()` worker thread. The diff code is serialized via `string.dump()` and run entirely off the main thread. Zero UI jank for large diffs.

**jj-signs**: No worker threads. `vim.diff()` for unsaved-buffer diffs runs synchronously on the main thread. For a 10k-line file with many changes, this can block the UI for tens of milliseconds.

**Gap**: Critical for large files. The fix is straightforward — wrap the `vim.diff()` call in `uv.new_work()` — but jj-signs doesn't do this yet.

#### 3. Incremental vs Full-Recompute

**gitsigns**: Hooks `nvim_buf_attach()` `on_lines` to get exact line change ranges. Can update only the affected sign range rather than re-diffing everything. Also maintains blame cache with line-indexed entries that update incrementally on edits.

**jj-signs**: No `nvim_buf_attach()`. Every trigger (including `TextChanged`) re-runs the full `vim.diff()` against `base_text`. For unsaved diffs, `table.concat(lines, "\n")` on every keystroke allocates a full string copy of the buffer.

**Gap**: On every keystroke in insert mode, jj-signs:
1. Allocates a full buffer string (`table.concat` on all lines)
2. Runs `vim.diff()` synchronously
3. Iterates all hunks to place extmarks

For a 5,000-line file, that's O(n) work per keypress. gitsigns' `on_lines` callback narrows the diff to the changed region.

#### 4. View-Aware Rendering

**gitsigns**: Decoration provider `on_win` checks visible range and only calls `on_line` for visible rows. Out-of-view buffers are flagged `update_on_view` and deferred until shown. This means background tabs consume no render cycles.

**jj-signs**: Has a decoration provider but `on_line` still iterates all hunks via `find_sign_at` (binary search). The binary search is efficient, but the provider fires for every visible line regardless of whether the buffer's hunks changed. The non-provider path (`signs.place`) iterates all hunks and places extmarks for all lines in every hunk on every refresh — even if nothing changed in view.

**Gap**: jj-signs lacks the `update_on_view` deferred update. A buffer opened in a background tab refreshes immediately on `BufEnter`, even if not visible to the user.

#### 5. Change Detection Granularity

**gitsigns**: Watches `.git/HEAD` and object store via `fs_event` + `fs_poll`. Detects HEAD moves (branch switches, amends, rebases) without user interaction. Uses HEAD OID tracking — knows the exact tree state, not just a hash string.

**jj-signs**: Polls `jj log -r @ -T change_id` (a subprocess) plus file `mtime`. This is:
- One subprocess call per refresh cycle just for change detection
- `change_id` is stable across jj operations that don't affect `@` (good), but won't detect parent changes in multi-commit stacks without a full re-diff

**Gap**: gitsigns' FS watcher triggers reactively — it knows when `.git/HEAD` changed. jj-signs detects changes only on user-triggered events (BufEnter, write, focus). If a user runs `jj squash` in another terminal while editing, signs won't update until they switch focus to Neovim.

A jj equivalent would watch `.jj/repo/op_log` or poll `jj op log` to detect external operations.

#### 6. Subprocess Cost

**gitsigns**: Reads git objects via `libgit2` bindings (in `git.lua`, `GitObj`). The blob content for comparison is fetched from the object store directly — no subprocess for the common case. Subprocesses used only for git blame and some metadata.

**jj-signs**: Every diff requires a `jj diff` subprocess. Every change detection requires a `jj log` subprocess. Every base text fetch requires a `jj file show` subprocess. Three subprocess calls per refresh in the worst case.

**Gap**: Fundamental — JJ has no library API, so subprocesses are unavoidable. But jj-signs could reduce calls: skip the `jj log` change_id check if only mtime changed (the diff itself will be the same regardless of change_id if the file didn't change), or batch the base fetch + diff into a single subprocess.

#### 7. Debounce Strategy

**gitsigns**: `throttle_async({ hash = 1, schedule = true })` — a missed update while one is running gets queued and re-fired once the current one finishes. No updates are dropped.

**jj-signs**: Plain trailing debounce with `uv.new_timer()`. If a refresh fires and another is triggered mid-flight, the trailing debounce may coalesce it, but there's no explicit "re-run if I was busy" logic. A rapid edit → save → jj op sequence could miss a refresh.

**Gap**: Minor, but jj-signs could miss a state change if events arrive too fast.

#### 8. Memory Model

**gitsigns**: `CacheEntry` holds `compare_text` (git blob content) keyed by OID. The same blob is reused across multiple buffer views of the same revision. `blame` cache stores per-line entries with `min_time`/`max_time` for the heat map — expensive but cached aggressively.

**jj-signs**: `base_text` is per-buffer string (not shared between buffers viewing the same file). If you have three windows on the same file, each buffer fetches and stores its own copy of the parent content.

**Gap**: Low severity for typical use, but memory doubles/triples with split views of the same file.

#### 9. Large File Guard

**gitsigns**: `max_file_length` (default 40,000 lines) — skips sign placement. Also gracefully handles files above this via sign count display.

**jj-signs**: `max_file_length` (default 40,000 lines) — skips `schedule_refresh` entirely. No fallback display.

**Parity**: Both have the guard. jj-signs matches gitsigns' default threshold.

---

### Test Coverage Gap

| Area | gitsigns | jj-signs |
|------|----------|----------|
| Unit tests | ✅ | ✅ |
| Integration (real repo) | ✅ (extensive) | ❌ |
| Screen rendering assertions | ✅ | ❌ |
| Async behavior | ✅ | ❌ |
| Subprocess/jj CLI interaction | ✅ (mocked) | ❌ |
| Watcher / FS event behavior | ✅ | ❌ |
| Debounce/throttle | ✅ | ❌ |
| Large file behavior | partial | ❌ |

jj-signs tests cover only pure Lua logic (parser, navigation, sign index). Everything that touches Neovim APIs, async behavior, or subprocess execution is untested.

---

### Priority Performance Gaps (Ordered by Impact)

1. **Worker thread for `vim.diff()`** — synchronous main-thread diff on every keypress in large files is the highest-severity gap. Blocks UI.

2. **`nvim_buf_attach` `on_lines`** — replace full-buffer `table.concat` per keypress with incremental change tracking. Reduces both allocation and diff scope.

3. **Reactive FS watching** — jj operations in another terminal go undetected. Need to watch `.jj/repo/op_log` or poll on a separate timer.

4. **`throttle_async` style update queuing** — current trailing debounce can miss a state change if events arrive in rapid succession.

5. **Shared `base_text` across buffer views** — low impact for most users, but easy win for split-window workflows.

6. **`update_on_view` deferral** — don't refresh background tab buffers until they become visible.
