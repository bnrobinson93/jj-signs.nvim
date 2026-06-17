# Partial Hunk Restore

## What

Restore a single hunk (revert its lines to the parent revision state), not the whole file. Mirrors gitsigns' `reset_hunk` which stages the inverse diff for just the hunk under cursor.

Current implementation restores the whole file with `jj restore --from @- -- <filepath>`. This spec replaces that with per-hunk precision.

---

## JJ Limitation

`jj restore` has no hunk-level flag. No `jj apply` equivalent exists. Must reconstruct the restore manually:

1. Read current buffer lines
2. Replace hunk's added lines with hunk's removed lines (the pre-change content)
3. Write patched content back to file
4. Trigger buffer reload

This is pure Lua string manipulation — no extra JJ subprocess needed.

---

## Algorithm

```lua
function M.restore_hunk(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local entry = cache.get(bufnr)
  if not entry then return end

  local lnum = api.nvim_win_get_cursor(0)[1]
  local hunk = hunks_mod.find_hunk(lnum, entry.hunks)
  if not hunk then
    vim.notify("jj-signs: no hunk at cursor", vim.log.levels.WARN)
    return
  end

  -- added.start is 1-indexed. nvim_buf_set_lines is 0-indexed, end-exclusive.
  local start0 = hunk.added.start - 1
  local end0   = hunk.added.start + hunk.added.count - 1  -- exclusive

  -- For delete hunk: added.start = line before deletion, added.count = 0
  -- Re-insert removed lines after that line.
  -- For add hunk: removed.count = 0 → remove inserted lines, insert nothing.
  -- For change: replace added lines with removed lines.

  api.nvim_buf_set_lines(bufnr, start0, end0, false, hunk.removed.lines)

  -- Write to disk so jj sees the change
  vim.cmd("update")
end
```

`hunk.removed.lines` is already stored by the diff parser (the `-` lines from the unified diff). This is the exact content to restore.

---

## Edge Cases

| Case | Behavior |
|------|----------|
| add hunk | `removed.lines = {}` → delete the added lines |
| delete hunk | `added.count = 0` → insert `removed.lines` after `added.start` |
| change hunk | replace `added.count` lines with `removed.lines` |
| topdelete | `added.start = 0` → prepend `removed.lines` at buffer start |

For topdelete: `nvim_buf_set_lines(bufnr, 0, 0, false, hunk.removed.lines)`.

---

## Config

No new config keys. This replaces the existing `restore_hunk` implementation.

---

## Keymap

Existing `<leader>ghr` keymap calls `M.restore_hunk()` — no change to keymap binding.

---

## Changes Required

| File | Change |
|------|--------|
| `init.lua` / `hunks.lua` | Replace whole-file `jj restore` with `nvim_buf_set_lines` approach |
| `hunks.lua` | Remove `vim.system` call for restore; use buffer API directly |

---

## Why Better

- No subprocess → instant
- Reversible by undoing (`u`) — the buffer edit goes on undo stack
- gitsigns' `reset_hunk` works same way (applies inverse patch to buffer)

---

## Size Estimate

Net ~-10 lines: remove async jj restore code, add ~25 lines synchronous buffer edit. Simpler overall.
