# Inline Blame

## What

Virtual text at end of current line showing who last touched it and when, sourced from `jj annotate`. Mirrors gitsigns' `current_line_blame`.

```
fn process(input: &str) -> Result<()> {      ‹ kkpqsvxy • brad • 3 hours ago
```

---

## JJ Command

```
jj annotate --color=never -- <filepath>
```

Output format (one line per source line):

```
kkpqsvxyzspo 2026-06-16 brad@example.com: actual file content here
```

Fields: `change_id` (12 chars), date, author email, `: `, line content.

Parse into: `{ change_id, date, author }` per line number.

---

## Data Model

```lua
BlameEntry = {
  change_id : string,   -- short change id
  author    : string,   -- from email, before @
  date      : string,   -- relative or absolute depending on config
}

-- per-buffer annotation cache
blame_cache[bufnr] = {
  change_id : string,   -- @ change_id when annotation was fetched
  entries   : table<integer, BlameEntry>,  -- line → entry
}
```

---

## Refresh Strategy

`jj annotate` is slower than `jj diff` (reads full file history). Run it lazily:

1. Only when `current_line_blame = true`
2. Trigger: `CursorHold`, `BufEnter` (not `CursorMoved` — too hot)
3. Cache by `change_id` — if `@` hasn't changed, reuse cached entries
4. Show blame for cursor line only (no full-buffer rendering)

---

## Rendering

```lua
nvim_buf_set_extmark(bufnr, blame_ns, lnum - 1, 0, {
  virt_text       = { { formatted_blame, "JJSignsCurrentLineBlame" } },
  virt_text_pos   = "eol",
  priority        = 100,
})
```

Format: `‹ {short_id} • {author} • {relative_date}`

Relative date: convert ISO date to "N hours/days/weeks ago" in Lua (no extra subprocess).

Clear previous blame extmark on every cursor move (`CursorMoved` autocmd clears; `CursorHold` re-adds with debounce).

---

## Config

```lua
current_line_blame = false,           -- disabled by default
current_line_blame_opts = {
  virt_text      = true,
  virt_text_pos  = "eol",             -- "eol" | "right_align"
  delay          = 1000,              -- ms before showing (matches gitsigns)
  format         = "‹ %s • %a • %r", -- %s=short_id, %a=author, %r=relative_date
},
```

---

## New Highlight Group

`JJSignsCurrentLineBlame` → links to `NonText` (dim, unobtrusive) — same as `GitSignsCurrentLineBlame`.

---

## New Module

`lua/jj-signs/blame.lua`

```
M.fetch(bufnr, root, filepath, cb)   — async jj annotate + parse
M.show(bufnr, lnum)                  — place virt_text for one line
M.clear(bufnr)                       — remove blame extmark
M.setup_autocmds(augroup)            — CursorHold / CursorMoved wiring
```

---

## Changes Required

| File | Change |
|------|--------|
| `blame.lua` | New module |
| `config.lua` | Add `current_line_blame`, `current_line_blame_opts` |
| `autocmds.lua` | Call `blame.setup_autocmds()` when config enabled |
| `signs.lua` | `setup_highlights()` adds `JJSignsCurrentLineBlame` |
| `init.lua` | Expose `toggle_current_line_blame()` on public API |

---

## JJ vs Git Difference

gitsigns blame shows git commit hash + author from `git blame`. Ours shows JJ `change_id` + author from `jj annotate`. The change_id is more meaningful in JJ workflows than a commit hash — it's stable across rebases.

---

## Size Estimate

| Module | ~Lines |
|--------|--------|
| `blame.lua` | 130 |
| Config + wiring | 30 |
| **Total** | **~160** |
