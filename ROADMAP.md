# Goal

Incremental improvements to the offering

Reference: `ANALYSIS.md` — gitsigns.nvim is the benchmark.

---

## Changes

1. **Parent change_id caching** — store `parent_change_id` (`jj log -r @- -T change_id`) in cache; invalidate `base_text` only when parent changes, not on every `@` op
2. **Reactive repo watching** — replace poll-on-focus with `uv.fs_event` on `.jj/repo/op_heads/`; signs update when jj ops land in another terminal
3. **Off-thread `vim.diff()`** — move synchronous unsaved-buffer diff to `uv.new_work()` worker thread; eliminates UI jank on large files
4. **Incremental buffer tracking** — replace full `table.concat` on every keypress with `nvim_buf_attach` `on_lines`; narrow diff scope to changed region
5. **Throttle-async update queuing** — replace trailing debounce with throttle+requeue pattern; no state changes dropped under rapid edits
6. **Shared `base_text` across buffers** — key base_text by `(filepath, parent_change_id)` not per-buffer; split views of same file share one fetch
7. **Defer background buffer updates** — skip refresh for buffers not visible in any window; schedule on `BufWinEnter`/`WinEnter` instead
8. **Integration test infrastructure** — real jj repo fixtures, async test gates, subprocess mocking

---

## Subtasks

### C1: Parent change_id + commit_id caching

**Context**: Currently `refresh()` calls `get_change_id` for `@` and compares mtime. `base_text` is invalidated whenever `@`'s `change_id` changes — but `base_text` is content of `@-`, not `@`. Two cases invalidate it independently:

- Parent swap: user runs `jj rebase -d other` — `@-`'s `change_id` changes entirely
- Parent amend: someone amends `@-` directly — `change_id` stays the same but content differs (new `commit_id`)

Composite key `parent_change_id + parent_commit_id` covers both. `commit_id` of `@-` is stable within a single amend but changes on rebase/squash; `change_id` catches parent swaps even when commit_id recycles.

- C1a: Add `parent_change_id` and `parent_commit_id` fields to `CacheEntry` type annotation in `cache.lua`
- C1b: In `diff.lua`, add `get_parent_ids(root, cb)` — single `jj log -r @- -T 'change_id ++ " " ++ commit_id' --no-graph --color=never`; parse both from stdout
- C1c: In `refresh()`, call `get_parent_ids`; invalidate `base_text` when either `parent_change_id` or `parent_commit_id` differs from cached values
- C1d: Update `cache.set()` call in `refresh()` to persist both parent id fields
- C1e: In `base_cache.lua` (C6), key entries by `filepath .. "|" .. parent_change_id .. "|" .. parent_commit_id`
- C1f: Test: `parent_change_id` mismatch (parent swap) triggers re-fetch; `parent_commit_id` mismatch alone (parent amended in place) also triggers re-fetch; both matching skips fetch

---

### C2: Reactive repo watching

**Context**: Currently signs only update on Neovim events (BufEnter, FocusGained). `jj squash`, `jj undo`, `jj new` in another terminal go undetected until the user switches focus.

- C2a: Create `lua/jj-signs/watcher.lua` module
- C2b: Implement `watcher.start(root, cb)` — `uv.fs_event` on `root .. "/.jj/repo/op_heads/"` with debounce (200ms); fall back to `uv.fs_poll` (500ms interval, fingerprint = dir mtime) if fs_event unsupported
- C2c: Implement `watcher.stop(root)` and ref-count by root (multiple buffers in same repo share one watcher)
- C2d: In `attach()`, start watcher for buffer's root; callback calls `cache.invalidate_all()` then schedules refresh for all attached buffers in that root
- C2e: In `detach()`, decrement ref count; stop watcher when count reaches 0
- C2f: Test: watcher fires after simulated op_heads dir change; debounce coalesces rapid changes

---

### C3: Off-thread `vim.diff()`

**Context**: Unsaved-buffer diff path calls `vim.diff()` synchronously on the main thread. On a 10k-line file this can block the UI for 20-50ms per keypress.

- C3a: In `diff.lua`, add `diff_async(base_text, buf_text, cb)` — serializes the diff call via `uv.new_work()`; passes result back via `vim.schedule(cb)`
- C3b: Replace synchronous `vim.diff()` call in `refresh()`'s `do_buf_diff()` with `diff_async()`
- C3c: Ensure generation counter check runs inside the `vim.schedule` callback (post-thread), not before dispatch
- C3d: Test: `diff_async` returns same results as synchronous `vim.diff()` for add/change/delete/empty cases

---

### C4: Incremental buffer tracking

**Context**: `TextChanged`/`TextChangedI` trigger `schedule_refresh` which eventually calls `table.concat(api.nvim_buf_get_lines(...))` — allocates a full string copy of the buffer on every keypress.

- C4a: In `attach()`, call `nvim_buf_attach(bufnr, false, { on_lines = ... })` to track dirty line ranges per buffer
- C4b: Store `dirty_range = { first, last }` in `CacheEntry` — updated by `on_lines` callback (union with existing dirty range)
- C4c: In `refresh()`'s modified-buffer path, if `dirty_range` is set: fetch only changed lines + context (±3 lines) and run `vim.diff()` on the narrowed region; merge result back into cached hunks
- C4d: Clear `dirty_range` after successful refresh
- C4e: Remove `TextChanged`/`TextChangedI` autocmds from `autocmds.lua` (replaced by `on_lines` callback)
- C4f: Test: `on_lines` correctly unions overlapping dirty ranges; narrow diff produces same hunk result as full diff for single-hunk edits

---

### C5: Throttle-async update queuing

**Context**: Current trailing debounce drops events that arrive while a refresh is in-flight. Rapid `jj` ops + file saves can miss a state change.

- C5a: Add `lua/jj-signs/async.lua` — lightweight coroutine Task wrapper (model after gitsigns `async.lua`); `async.run()`, `async.wrap()`, `async.schedule()`
- C5b: Add `throttle_async(fn, opts)` to `async.lua` — per-buffer keyed; if a call arrives while one is running, set `pending = true`; re-invoke `fn` once current finishes
- C5c: Replace `timers` debounce table in `autocmds.lua` with `throttle_async`-wrapped `refresh`
- C5d: Remove manual generation counter in `init.lua` (`refresh_gens`) — stale-callback cancellation handled by throttle
- C5e: Test: throttle coalesces 5 rapid calls into at most 2 executions (one running + one queued); no calls lost

---

### C6: Shared `base_text` across buffers

**Context**: If three windows show the same file, each buffer independently fetches and stores the parent content string (`jj file show -r @-`). Wastes memory and subprocess calls.

- C6a: Add `lua/jj-signs/base_cache.lua` — module-level table keyed by `filepath .. "|" .. parent_change_id .. "|" .. parent_commit_id`; `get(key)`, `set(key, text)`, `evict_stale(active_keys)`
- C6b: In `refresh()`'s `fetch_base` call, check `base_cache.get()` first; on miss fetch and store
- C6c: On detach, call `evict_stale` with all active `(filepath, parent_change_id)` keys still in use
- C6d: Remove `base_text` field from `CacheEntry` (now lives in `base_cache`)
- C6e: Test: two buffers with same filepath + parent_change_id + parent_commit_id share one fetch (mock `vim.system` call count = 1)

---

### C7: Defer background buffer updates

**Context**: `BufEnter` fires for background buffers (e.g. when cycling tabs). Every attached buffer refreshes even if not visible.

- C7a: In `autocmds.schedule_refresh`, add visibility check: skip if buffer has no window (`#api.nvim_get_buf_windows(bufnr) == 0`)
- C7b: Track `update_on_view = true` on `CacheEntry` when refresh is skipped due to no window
- C7c: Add `WinEnter`/`BufWinEnter` autocmd: if `entry.update_on_view`, clear flag and schedule refresh
- C7d: Test: buffer with no window skips refresh; refresh fires when window opens

---

### C8: Integration test infrastructure

**Context**: All current tests are pure-Lua unit tests. Nothing tests subprocess calls, async behavior, decoration provider rendering, or real jj repo state.

- C8a: Add `test/fixtures.lua` — `make_jj_repo()` creates temp dir, runs `jj git init`, writes files, returns root path; `cleanup()` removes it
- C8b: Add `test/async_helpers.lua` — `wait_until(cond, timeout_ms)` polls via `vim.wait`; `wait_for_refresh(bufnr)` waits for `entry.dirty == false`
- C8c: Add `test/integration/attach_spec.lua` — opens real file in real jj repo, calls `M.attach()`, asserts cache populated and signs placed
- C8d: Add `test/integration/refresh_spec.lua` — modifies file via `jj` CLI, calls `M.refresh()`, asserts hunks updated
- C8e: Add `test/integration/watcher_spec.lua` (after C2) — modifies repo via `jj new` in subprocess, asserts watcher fires and signs update without explicit refresh
- C8f: CI: update `.github/workflows/ci.yml` to install `jj` binary before running tests
