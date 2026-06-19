# jj-signs.nvim

Inline change annotations for Neovim in [JJ](https://github.com/martinvonz/jj) repositories — the `gitsigns.nvim` equivalent that didn't exist yet.

Shows which lines in the current buffer are part of the current JJ change (`@`) compared to its parent:

```
▎  added line          — green sign
▎  modified line       — yellow sign
▁  deleted below       — red underscore at deletion point
▔  deleted at top      — red overscore (topdelete)
▎  modified + shrunk   — yellow/red (changedelete)
╪  conflict line       — red, distinct from normal diffs
```

Signs refresh automatically on `BufEnter`, `BufWritePost`, and `FocusGained`. No manual command needed.

## Requirements

- Neovim ≥ 0.10
- [`jj`](https://github.com/martinvonz/jj) installed and in `$PATH`

## Installation

### lazy.nvim

```lua
{
  "your-username/jj-signs.nvim",
  event = "LazyFile",
  opts = {},
}
```

## Configuration

All options with their defaults:

```lua
require("jj-signs").setup({
  signs = {
    add          = { text = "▎", hl = "JJSignsAdd" },
    change       = { text = "▎", hl = "JJSignsChange" },
    delete       = { text = "▁", hl = "JJSignsDelete" },
    topdelete    = { text = "▔", hl = "JJSignsTopDelete" },
    changedelete = { text = "▎", hl = "JJSignsChangedelete" },
    conflict     = { text = "╪", hl = "JJSignsConflict" },
  },
  signcolumn      = true,
  numhl           = false,   -- highlight the number column
  linehl          = false,   -- highlight the full line
  word_diff       = false,   -- intra-line word highlights on changed lines
  show_deleted    = false,   -- render deleted lines as dimmed virtual text
  update_debounce = 100,
  max_file_length = 40000,
  sign_priority   = 6,
  use_decoration_provider = true,  -- render signs lazily for visible lines only
  jj_cmd          = "jj",
  -- Optional: passed as `jj --repository <path>` to every jj call.
  -- Leave nil — cwd-based workspace detection handles all standard JJ setups.
  jj_repo         = nil,
  -- Called after attaching to a buffer. Set up buffer-local keymaps here.
  -- Return false to cancel the attach. When nil, built-in default keymaps are used.
  on_attach       = nil,

  -- Inline blame (disabled by default)
  current_line_blame = false,
  current_line_blame_opts = {
    virt_text     = true,
    virt_text_pos = "eol",   -- "eol" | "right_align"
    delay         = 1000,    -- ms after CursorHold before showing
    format        = "‹ %s • %a • %r",  -- %s=change_id, %a=author, %r=relative date
  },
})
```

## Keymaps

Default keymaps are buffer-local and set during attach. They match [LazyVim's gitsigns layout](https://www.lazyvim.org/plugins/editor#gitsignsnvim) so muscle memory transfers when migrating from Git to JJ.

| Key             | Mode    | Action                                  |
|-----------------|---------|-----------------------------------------|
| `]h`            | n       | Jump to next hunk                       |
| `[h`            | n       | Jump to previous hunk                   |
| `]H`            | n       | Jump to last hunk                       |
| `[H`            | n       | Jump to first hunk                      |
| `<leader>ghp`   | n       | Preview hunk in floating window         |
| `<leader>ghr`   | n       | Restore hunk to `@-` state             |
| `<leader>ghd`   | n       | Diff current file vs `@-` in vimdiff   |
| `<leader>ghD`   | n       | Diff vs a prompted revision             |
| `ih`            | x, o    | Select hunk (inner hunk text object)   |

`restore_hunk` applies a per-hunk restore using `nvim_buf_set_lines` — no subprocess, instant, and undoable with `u`.

### Custom keymaps

Override `on_attach` to replace the default keymaps entirely:

```lua
require("jj-signs").setup({
  on_attach = function(bufnr)
    local jj = require("jj-signs")
    local map = function(mode, key, fn, desc)
      vim.keymap.set(mode, key, fn, { buffer = bufnr, desc = desc })
    end
    map("n", "]h",          function() jj.nav_hunk("next")  end, "Next JJ hunk")
    map("n", "[h",          function() jj.nav_hunk("prev")  end, "Prev JJ hunk")
    map("n", "<leader>ghp", jj.preview_hunk,                    "Preview JJ hunk")
    map("n", "<leader>ghr", jj.restore_hunk,                    "Restore hunk from @-")
    map({"x","o"}, "ih",    jj.select_hunk,                     "Select hunk")
  end,
})
```

## Inline Blame

When `current_line_blame = true`, the author and relative date of the last change to the cursor line appear as virtual text at end-of-line after `CursorHold`:

```
fn process(input: &str) -> Result<()> {      ‹ kkpqsvxy • brad • 3 days ago
```

Blame is sourced from `jj annotate` and cached per `change_id`. Toggle at runtime:

```lua
require("jj-signs").toggle_current_line_blame()
```

## Statusline Integration

```lua
-- lualine component
{
  function()
    local s = require("jj-signs").summary()
    local parts = {}
    if s.added   > 0 then parts[#parts+1] = "+" .. s.added   end
    if s.changed > 0 then parts[#parts+1] = "~" .. s.changed end
    if s.deleted > 0 then parts[#parts+1] = "-" .. s.deleted end
    return table.concat(parts, " ")
  end,
  cond = function()
    local s = require("jj-signs").summary()
    return s.added + s.changed + s.deleted + s.conflicts > 0
  end,
}
```

## Public API

| Function | Description |
|----------|-------------|
| `setup(opts)` | Initialize with config |
| `attach(bufnr?)` | Attach to buffer (called automatically) |
| `detach(bufnr?)` | Detach and clear signs |
| `refresh(bufnr?)` | Force re-check change_id + mtime and redraw |
| `nav_hunk(direction)` | Navigate: `"next"` `"prev"` `"first"` `"last"` |
| `preview_hunk()` | Float showing removed/added lines |
| `restore_hunk()` | Replace hunk lines with `@-` content via buffer API |
| `select_hunk(bufnr?)` | Set visual selection to hunk lines |
| `diffthis(rev?)` | Open vimdiff vs `rev` (default `"@-"`) |
| `diffthis_rev()` | Prompt for revision, then open vimdiff |
| `toggle_current_line_blame()` | Toggle inline blame |
| `summary()` | Return `{ added, changed, deleted, conflicts }` |

## Highlights

Default highlight groups link to standard Neovim diff groups so any colorscheme works:

| Group                    | Links to          | Purpose |
|--------------------------|-------------------|---------|
| `JJSignsAdd`             | `Added` / `DiffAdd`    | Added lines |
| `JJSignsChange`          | `Changed` / `DiffChange` | Changed lines |
| `JJSignsDelete`          | `Removed` / `DiffDelete` | Deleted lines |
| `JJSignsTopDelete`       | `Removed` / `DiffDelete` | Deletion at file top |
| `JJSignsChangedelete`    | `Changed` / `DiffChange` | Change that shrinks |
| `JJSignsConflict`        | `DiagnosticError` | Conflict markers |
| `JJSignsAddWord`         | `Added` / `DiffAdd`    | Word diff inline (added) |
| `JJSignsChangeWord`      | `Changed` / `DiffChange` | Word diff inline (changed) |
| `JJSignsDeleteWord`      | `Removed` / `DiffDelete` | Word diff inline (deleted) |
| `JJSignsDeleteVirtLn`    | `DiffDelete`      | show_deleted virtual lines |
| `JJSignsCurrentLineBlame`| `NonText`         | Inline blame text |
| `JJSigns*Nr`             | `JJSigns*`        | Number column variants (numhl) |
| `JJSigns*Ln`             | diff groups       | Line highlight variants (linehl) |

Override any group in your config:
```lua
vim.api.nvim_set_hl(0, "JJSignsAdd", { fg = "#00ff00" })
```

## JJ Workspaces

Multiple JJ workspaces (`jj workspace add`) are supported automatically. Each workspace has its own `@`, and signs reflect whichever workspace owns the file being edited. No configuration needed — the plugin detects the workspace root via `jj root` from the file's directory.

If you access files from outside their workspace (symlinks, remote mounts, etc.), set `jj_repo` to the workspace root:

```lua
require("jj-signs").setup({
  jj_repo = "/path/to/workspace",
})
```

## What It Does Not Do

- No staging (JJ has no index)
- No signs for changes other than `@` vs its parent
- No hunk-level CLI operations — restore uses the buffer API, diff uses a temp file

## Credits

Sign rendering, hunk calculation, and navigation logic are adapted from
[**gitsigns.nvim**](https://github.com/lewis6991/gitsigns.nvim) by Lewis Russell,
used under the [MIT License](https://github.com/lewis6991/gitsigns.nvim/blob/main/LICENSE).

## License

MIT
