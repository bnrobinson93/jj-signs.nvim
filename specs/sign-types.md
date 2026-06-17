# Sign Types: topdelete + changedelete

## What

Two sign types present in gitsigns that jj-signs currently collapses into `delete` and `change`.

```
▔  topdelete    — deletion that removed lines at/before the first line of the file
▎  changedelete — change hunk where more lines were removed than added (truncation)
```

---

## Why These Are Distinct

`topdelete` needs a different character because the deletion point is before line 1 — there is no line to attach a sign to below the deletion. The sign must sit on line 1 pointing upward.

`changedelete` signals "this line was modified AND lines below it disappeared" — more information than a plain change sign.

---

## Detection Logic

Both are derived from existing hunk data, no new diff parsing needed.

```lua
-- topdelete: delete hunk where the deletion is at or before the file start
hunk.type == "delete" and hunk.added.start == 0

-- changedelete: change hunk where removed > added
-- OR: a change hunk immediately followed by a delete hunk on its last line
hunk.type == "change" and (
  hunk.removed.count > hunk.added.count
  or (next_hunk and next_hunk.type == "delete"
      and next_hunk.added.start == hunk.added.start + hunk.added.count - 1)
)
```

`calc_signs()` in `signs.lua` needs access to `next_hunk` to detect the second `changedelete` case. Pass it from `place()` which iterates the full hunk list.

---

## Config Changes

```lua
signs = {
  add          = { text = "▎", hl = "JJSignsAdd" },
  change       = { text = "▎", hl = "JJSignsChange" },
  delete       = { text = "▁", hl = "JJSignsDelete" },
  topdelete    = { text = "▔", hl = "JJSignsTopDelete" },   -- NEW
  changedelete = { text = "▎", hl = "JJSignsChangedelete" }, -- NEW
  conflict     = { text = "╪", hl = "JJSignsConflict" },
}
```

`JJSignsTopDelete` → link to `Removed` / `DiffDelete`  
`JJSignsChangedelete` → link to `Changed` / `DiffChange`

---

## Changes Required

| File | Change |
|------|--------|
| `config.lua` | Add `topdelete` + `changedelete` to defaults |
| `signs.lua` | `place()` passes `next_hunk` to `calc_signs()`; `calc_signs()` returns sign type per line |
| `signs.lua` | `setup_highlights()` adds two new groups |
| `diff.lua` | `JJSigns.HunkType` alias adds the two new types |
| `hunks.lua` | `get_summary()` counts changedelete as changed, topdelete as deleted |

---

## Size Estimate

~40 lines across the modified files. No new modules needed.
