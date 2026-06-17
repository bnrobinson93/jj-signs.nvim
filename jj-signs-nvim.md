# jj-signs.nvim

Inline change annotations for Neovim in JJ repos. The `gitsigns.nvim` equivalent that doesn't exist yet.

## What It Does

Shows which lines in the current buffer are part of the current JJ change (`@`) compared to its parent:

```
│  added line      — green sign in signcolumn
│  modified line   — yellow sign
_  deleted above   — red underscore at deletion point
╪  conflict line   — red, distinct from normal diffs
```

Refreshes automatically. No command needed — the change state is always ambient.

---

## Why This Gap Exists

`gitsigns.nvim` reads from `.git` object store via `libgit2`. JJ doesn't expose a stable library interface — you go through the CLI. That's slower (subprocess per refresh) but manageable with caching and debounce. No existing plugin does it.

---

## Data Model

```lua
-- per-buffer state
BufferState = {
  bufnr     : number,
  path      : string,           -- absolute path
  hunks     : Hunk[],           -- parsed from jj diff
  ns_id     : number,           -- extmark namespace
  dirty     : bool,             -- needs refresh
  last_rev  : string,           -- change_id of @ when last refreshed
}

Hunk = {
  type      : "add" | "del" | "mod" | "conflict",
  start     : number,           -- 1-indexed line
  count     : number,           -- line count (0 for del = shows below)
  -- for deletions: line where deleted block appeared above
  del_line  : number | nil,
}
```

---

## Module Structure

```
lua/jj-signs/
  init.lua      — setup(), attach(), detach(), public API
  config.lua    — defaults + user overrides
  diff.lua      — async jj diff runner + unified diff parser
  signs.lua     — extmark placement / clearing per buffer
  hunks.lua     — hunk navigation, preview float
  autocmds.lua  — BufEnter, BufWritePost, FocusGained triggers
  cache.lua     — repo-level change_id cache, invalidation
```

---

## Refresh Strategy

**Trigger points:** `BufEnter`, `BufWritePost`, `FocusGained`  
**Debounce:** 150ms — skip if another refresh is already pending for this buffer  
**Skip conditions:**
- File not in a JJ repo (`jj root` fails)
- Buffer is not a normal file (terminal, help, etc.)
- File is not tracked by JJ (new file not yet in any change)

**Cache invalidation:** Store the current `change_id` of `@`. On trigger, check if change_id changed (fast: `jj log -r @ -T change_id` is near-instant). If same change_id and file mtime unchanged → skip subprocess, keep existing signs.

**Async:** All `jj diff` calls use `vim.system` (nvim 0.10+) or `vim.fn.jobstart`. Never block the UI thread.

---

## Diff Parsing

Source: `jj diff --git --no-color -r @ -- <filepath>`

Parse standard unified diff format:

```
@@ -10,4 +10,6 @@
 context
+added line
+added line
 context
-removed line
+modified line (shown as del+add pair)
```

Map to hunks:
- Consecutive `+` lines with no preceding `-` → `add`
- Consecutive `-` lines with no following `+` → `del` (mark at line before)
- `-`/`+` pair → `mod` (mark the `+` lines)

Conflict markers: scan for `<<<<<<< Conflict` in buffer lines. These are JJ-format conflicts (multiple base/left/right sections, different from git 3-way). Flag those lines as `conflict` type regardless of diff output.

---

## Sign Display

Use `vim.api.nvim_buf_set_extmark` with `sign_text` and `sign_hl_group`:

```lua
-- sign column
signs = {
  add      = { text = "│", hl = "JJSignsAdd" },      -- links to DiffAdd
  change   = { text = "│", hl = "JJSignsChange" },   -- links to DiffChange
  delete   = { text = "_", hl = "JJSignsDelete" },   -- links to DiffDelete
  conflict = { text = "╪", hl = "JJSignsConflict" }, -- links to DiagnosticError
}
```

Default highlights link to standard diff groups so any colorscheme works.

---

## Hunk Navigation

```
]j   — next hunk in current change
[j   — previous hunk in current change
```

Preview: `<leader>jp` → floating window showing hunk diff (the `±` lines from `jj diff`).

Restore hunk: `<leader>jr` → runs `jj restore --from @- <filepath>` for selected hunk range. Effectively: discard this hunk from the current change, pull the original from parent. Destructive — confirm prompt.

---

## Integration Points

**With `jj.nvim` (NicolasGB):** jj-signs is read-only — it only displays. All mutations (`new`, `describe`, `squash`) stay in `jj.nvim`. No API coupling needed. Both can coexist.

**With lualine:** Export `require("jj-signs").summary()` → `{ added: N, changed: N, deleted: N, conflicts: N }` for statusline component.

**Workspace awareness:** Signs show diff for whatever `@` is in the current workspace. If you open a file from an agent workspace directory, signs reflect the agent's current change. No special handling needed — just runs `jj diff` from the file's directory.

---

## What It Does NOT Do

- No staging (JJ has none)
- No blame per line (separate concern — `jj annotate`)
- No diff for arbitrary revisions (that's `<leader>jD` in jj.nvim)
- No signs for parent changes (only current `@`)
- No virtual text (only signcolumn)

---

## Configuration

```lua
require("jj-signs").setup({
  signs = {
    add      = { text = "│" },
    change   = { text = "│" },
    delete   = { text = "_" },
    conflict = { text = "╪" },
  },
  debounce_ms = 150,
  keymaps = {
    next_hunk    = "]j",
    prev_hunk    = "[j",
    preview_hunk = "<leader>jp",
    restore_hunk = "<leader>jr",
  },
  -- disable for large files
  max_file_lines = 10000,
})
```

---

## Size Estimate

| Module | ~Lines |
|--------|--------|
| diff.lua (runner + parser) | 150 |
| signs.lua (extmarks) | 80 |
| hunks.lua (nav + preview) | 100 |
| autocmds + cache | 80 |
| init + config | 60 |
| **Total** | **~470** |

---

## Publish Consideration

This fills a gap the whole JJ+nvim community has. After it works locally, extract into a standalone plugin repo. The only dependency should be nvim 0.10+ (for `vim.system`). No coupling to `jj.nvim` — someone could use this without it.
