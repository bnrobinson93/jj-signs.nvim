# Decoration Provider (Performance)

## What

Replace extmark-per-line sign placement with a Neovim decoration provider that only renders signs for visible lines. For large files, this avoids placing thousands of extmarks upfront.

Mirrors gitsigns' use of `nvim_set_decoration_provider` (added in nvim 0.6, used by gitsigns since ~2022).

---

## Why

Current approach: `signs.place()` calls `nvim_buf_set_extmark` for every line of every hunk, every refresh. A 5000-line file with diffs on 200 lines = 200 extmark calls per refresh.

With decoration provider: store hunks in cache, render signs only for the viewport window currently being drawn. Neovim calls the provider's `on_win` + `on_line` callbacks during each redraw, passing the visible line range.

---

## API

```lua
vim.api.nvim_set_decoration_provider(ns, {
  on_win = function(_, winid, bufnr, topline, botline)
    -- Called before each window redraw with visible line range.
    -- Store topline/botline for use in on_line.
  end,
  on_line = function(_, winid, bufnr, lnum)
    -- Called for each visible line. Place sign if a hunk covers lnum+1.
  end,
})
```

`on_line` is called with 0-indexed `lnum`. Signs must be placed here instead of upfront.

---

## Design

### Lookup structure

Binary-search–friendly hunk index for O(log n) per-line lookup:

```lua
-- Build once after diff parse, store in cache:
cache[bufnr].hunk_index = build_index(hunks)

-- build_index: sorted array of {start, end, sign_type} — same data as hunks but flat
-- find_sign_at(lnum, index) → sign_type or nil (binary search)
```

### Provider registration

Register once in `signs.setup()`:

```lua
local provider_registered = false

function M.setup()
  if provider_registered then return end
  provider_registered = true
  api.nvim_set_decoration_provider(ns, {
    on_win  = on_win,
    on_line = on_line,
  })
end
```

Provider is global per-namespace — registered once, fires for all buffers using the namespace.

### on_win

```lua
local function on_win(_, _, bufnr, topline, botline)
  -- Validate this is a tracked buffer
  if not cache.get(bufnr) then return false end
  -- Return true to enable on_line calls for this window
  return true
end
```

### on_line

```lua
local function on_line(_, _, bufnr, lnum)
  local entry = cache.get(bufnr)
  if not entry or not entry.hunk_index then return end

  local sign = find_sign_at(lnum + 1, entry.hunk_index)  -- convert to 1-indexed
  if not sign then return end

  api.nvim_buf_set_extmark(bufnr, ns, lnum, 0, {
    sign_text     = config.config.signs[sign.type].text,
    sign_hl_group = config.config.signs[sign.type].hl,
    priority      = config.config.sign_priority,
  })
end
```

---

## Migration Path

This is a backwards-compatible internal refactor — same visible behavior, better performance.

Steps:
1. Keep `signs.place()` for `numhl` and `linehl` (full-buffer extmarks, simpler to manage)
2. Replace `sign_text` extmarks with decoration provider
3. Remove per-line extmark loop from `signs.place()`

Or: implement decoration provider as opt-in config flag first, validate parity, then make default.

```lua
use_decoration_provider = true,  -- default true once stable
```

---

## Tradeoffs

| | Current (upfront) | Decoration provider |
|--|--|--|
| Initial render | O(hunks × lines) extmark calls | 0 upfront extmark calls |
| Scroll render | Nothing | O(visible hunk lines) per redraw |
| Large files | Slow on refresh | Fast always |
| Complexity | Simple | Higher (provider lifecycle) |
| `numhl`/`linehl` | Easy | Harder (need full-buffer for line hl) |

For small files (<500 lines with hunks), difference is imperceptible. Provider mainly helps 5k+ line files with many hunks.

---

## Changes Required

| File | Change |
|------|--------|
| `signs.lua` | `setup()` registers decoration provider |
| `signs.lua` | `place()` only builds `hunk_index` + handles numhl/linehl; skips sign_text extmarks |
| `signs.lua` | `clear()` still clears namespace (removes any placed extmarks) |
| `cache.lua` | Add `hunk_index` field to entry |
| `config.lua` | Optional: `use_decoration_provider = true` flag |

---

## Size Estimate

~80 lines in `signs.lua` (new provider callbacks + binary search). Net change after removing upfront loop: ~+40 lines.

---

## Neovim Version

`nvim_set_decoration_provider` available since nvim 0.6. Our minimum is 0.10. No version guard needed.
