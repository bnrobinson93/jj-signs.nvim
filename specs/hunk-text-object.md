# Hunk Text Object

## What

Visual and operator mode text object `ih` ("inner hunk") selecting the lines of the nearest hunk. Lets you `vih` to visually select a hunk, `dih`/`cih` to delete/change, `yih` to yank, etc. Mirrors gitsigns' `select_hunk` text object.

```
vih   — visually select hunk lines
dih   — delete hunk lines
yih   — yank hunk lines
```

---

## What "Hunk Lines" Means

Select the added lines (the lines actually in the buffer) for the hunk under cursor. For a delete hunk (no buffer lines), select the single deletion marker line.

```
[add hunk, lines 5-8]     → select lines 5–8
[change hunk, lines 3-3]  → select line 3
[delete hunk at line 7]   → select line 7 (the line the sign is on)
```

---

## Implementation

Map in operator-pending and visual modes. Use a function that:

1. Gets cursor line
2. Calls `find_hunk(lnum, cache.get(bufnr).hunks)` 
3. Sets visual selection from `hunk.added.start` to `hunk.added.start + hunk.added.count - 1`

```lua
function M.select_hunk(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local entry = cache.get(bufnr)
  if not entry or not entry.hunks then return end

  local lnum = api.nvim_win_get_cursor(0)[1]
  local hunk = hunks_mod.find_hunk(lnum, entry.hunks)
  if not hunk then return end

  local first = hunk.added.start
  local last  = hunk.added.start + math.max(hunk.added.count, 1) - 1

  -- Set visual selection
  vim.cmd("normal! " .. first .. "GV" .. last .. "G")
end
```

For delete hunks (`hunk.added.count == 0`), clamp to `math.max(1, hunk.added.start)` to land on the deletion sign line.

---

## Config

No new config keys. Keymap is added in `default_keymaps` alongside other hunk maps.

```lua
-- In default_keymaps(bufnr):
map({"x", "o"}, "ih", function() M.select_hunk(bufnr) end, "Select hunk")
```

---

## Changes Required

| File | Change |
|------|--------|
| `init.lua` | Add `select_hunk(bufnr)` function |
| `init.lua` | Add `{"x","o"} "ih"` mapping in `default_keymaps` |
| `init.lua` | Expose `select_hunk` on public API |

---

## Size Estimate

~15 lines in `init.lua`. No new module, no new config.
