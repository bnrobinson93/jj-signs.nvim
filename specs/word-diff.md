# Word Diff

## What

Intra-line highlighting on changed lines showing exactly which words or characters differ, not just which lines. Renders as extmark highlights overlaid on buffer text.

```
-old line with changed word here
+new line with changed word there
                           ^^^^^ highlighted inline
```

---

## JJ Specifics

No JJ CLI involvement. We already have `removed.lines` and `added.lines` for every change hunk. Word diff is pure Lua processing on those strings using `vim.diff`.

---

## Data Model

```lua
-- Per changed-line, list of byte ranges that differ
WordRegion = {
  lnum      : integer,  -- 1-indexed buffer line
  start_col : integer,  -- 0-indexed byte offset
  end_col   : integer,
}
```

---

## Implementation

### Computing word regions

Use `vim.diff` in `indices` mode on the removed/added line pairs from each change hunk:

```lua
-- For each change hunk:
local removed_regions, added_regions = run_word_diff(hunk.removed.lines, hunk.added.lines)
```

`run_word_diff` splits each line by word boundaries, diffs the word arrays, maps back to byte offsets. This is the same algorithm as `gitsigns/diff_int.lua::run_word_diff`. Can be lifted directly with minor adaptation (remove gitsigns-specific config references).

### Rendering

Place extmarks with `hl_group` (not `sign_text`) targeting the buffer text columns:

```lua
nvim_buf_set_extmark(bufnr, word_ns, lnum - 1, start_col, {
  end_col   = end_col,
  hl_group  = "JJSignsChangeWord",
  priority  = config.sign_priority + 1,
})
```

Use a separate namespace `"jj-signs-word"` so word highlights can be cleared independently from sign-column marks.

### Trigger

Computed alongside regular hunk placement in `signs.place()` when `config.word_diff == true`. Clear and re-place on every refresh — same lifecycle as sign extmarks.

---

## Config

```lua
word_diff = false,  -- disabled by default, matches gitsigns
```

---

## New Highlight Groups

| Group | Links to | Purpose |
|-------|----------|---------|
| `JJSignsAddWord` | `JJSignsAdd` with bg | Added word inline |
| `JJSignsChangeWord` | `JJSignsChange` with bg | Changed word inline |
| `JJSignsDeleteWord` | `JJSignsDelete` with bg | Deleted word inline (shown in preview) |

In practice, these need a visible background since they overlay text. Derive them from existing groups by reading `fg` and using it as `bg`, same as `GitSignsAddInline` etc.

---

## New Module

`lua/jj-signs/word_diff.lua`

```
run_word_diff(removed_lines, added_lines) → removed_regions[], added_regions[]
place_word_diff(bufnr, hunks)
clear_word_diff(bufnr)
```

---

## Changes Required

| File | Change |
|------|--------|
| `word_diff.lua` | New module — word diff computation + placement |
| `config.lua` | Add `word_diff = false` |
| `signs.lua` | Call `word_diff.place_word_diff(bufnr, hunks)` when enabled |
| `signs.lua` | `clear()` also clears word diff namespace |
| `signs.lua` | `setup_highlights()` adds word diff groups |

---

## Size Estimate

| Module | ~Lines |
|--------|--------|
| `word_diff.lua` | 120 |
| Other changes | 30 |
| **Total** | **~150** |
