# show_deleted (Virtual Lines)

## What

Render deleted lines inline in the buffer as virtual text, so you can see what was removed without leaving the file. Mirrors gitsigns' `show_deleted`.

```
 fn process(input: &str) {          ← real line (changed)
 fn process(input: &str) -> bool {  ← virtual line (what it was before, dimmed)
```

Deleted lines appear as dimmed virtual lines above their deletion point. Does not affect buffer content — purely visual.

---

## Data Model

No new data needed. `hunk.removed.lines` already stores the pre-change content for every delete and change hunk.

---

## Rendering

Use `virt_lines` on the extmark at the deletion point:

```lua
-- For a delete hunk at added.start (or line 1 for topdelete):
nvim_buf_set_extmark(bufnr, deleted_ns, lnum - 1, 0, {
  virt_lines = vim.tbl_map(function(l)
    return { { l, "JJSignsDeleteVirtLn" } }
  end, hunk.removed.lines),
  virt_lines_above = true,
})

-- For a change hunk, show removed lines above the changed lines:
nvim_buf_set_extmark(bufnr, deleted_ns, hunk.added.start - 1, 0, {
  virt_lines = vim.tbl_map(function(l)
    return { { l, "JJSignsDeleteVirtLn" } }
  end, hunk.removed.lines),
  virt_lines_above = true,
})
```

Use a separate namespace `"jj-signs-deleted"` to clear independently.

---

## Config

```lua
show_deleted = false,  -- disabled by default, matches gitsigns
```

---

## New Highlight Groups

| Group | Links to | Purpose |
|-------|----------|---------|
| `JJSignsDeleteVirtLn` | `DiffDelete` | Deleted lines rendered as virtual text |

---

## Changes Required

| File | Change |
|------|--------|
| `config.lua` | Add `show_deleted = false` |
| `signs.lua` | `place()` calls `place_deleted_lines(bufnr, hunks)` when enabled |
| `signs.lua` | `clear()` also clears deleted namespace |
| `signs.lua` | `setup_highlights()` adds `JJSignsDeleteVirtLn` |

No new module — logic fits in `signs.lua` (~40 lines).

---

## Constraint

`virt_lines` with `virt_lines_above = true` requires Neovim ≥ 0.10 — already our minimum.

For large hunks (many deleted lines), this can make the buffer visually noisy. Consider capping virtual line display at N lines per hunk (e.g. 20), same cap gitsigns uses.

---

## Size Estimate

~50 lines total across `signs.lua` and `config.lua`.
