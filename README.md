# jj-signs.nvim

Inline change annotations for Neovim in [JJ](https://github.com/martinvonz/jj) repositories — the `gitsigns.nvim` equivalent that didn't exist yet.

Shows which lines in the current buffer are part of the current JJ change (`@`) compared to its parent:

```
▎  added line      — green sign in signcolumn
▎  modified line   — yellow sign
▁  deleted above   — red underscore at deletion point
╪  conflict line   — red, distinct from normal diffs
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
    add      = { text = "▎", hl = "JJSignsAdd" },
    change   = { text = "▎", hl = "JJSignsChange" },
    delete   = { text = "▁", hl = "JJSignsDelete" },
    conflict = { text = "╪", hl = "JJSignsConflict" },
  },
  signcolumn      = true,
  numhl           = false,  -- highlight the number column
  linehl          = false,  -- highlight the full line
  update_debounce = 100,
  max_file_length = 40000,
  sign_priority   = 6,
  jj_cmd          = "jj",
  -- Optional: passed as `jj --repository <path>` to every jj call.
  -- Leave nil — cwd-based workspace detection handles all standard JJ setups.
  jj_repo         = nil,
  -- Called after attaching to a buffer. Set up buffer-local keymaps here.
  -- Return false to cancel the attach. When nil, built-in default keymaps are used.
  on_attach       = nil,
})
```

## Keymaps

Default keymaps are **buffer-local** and set via the `on_attach` callback.
They intentionally match [LazyVim's gitsigns layout](https://www.lazyvim.org/plugins/editor#gitsignsnvim)
so muscle memory transfers directly when migrating from Git to JJ.

| Key             | Action                          | LazyVim gitsigns equivalent |
|-----------------|---------------------------------|-----------------------------|
| `]h`            | Jump to next hunk               | `]h`                        |
| `[h`            | Jump to previous hunk           | `[h`                        |
| `]H`            | Jump to last hunk               | `]H`                        |
| `[H`            | Jump to first hunk              | `[H`                        |
| `<leader>ghp`   | Preview hunk in floating window | `<leader>ghp`               |
| `<leader>ghr`   | Restore file from `@-`          | `<leader>ghr` (reset hunk)  |

> **Note:** `restore_hunk` restores the entire file from the parent change (`@-`), not just the
> hunk under cursor. JJ's CLI does not currently support partial hunk restore.

### Custom keymaps

Override `on_attach` to replace the default keymaps entirely:

```lua
require("jj-signs").setup({
  on_attach = function(bufnr)
    local jj = require("jj-signs")
    local map = function(key, fn, desc)
      vim.keymap.set("n", key, fn, { buffer = bufnr, desc = desc })
    end
    map("]h", function() jj.nav_hunk("next")  end, "Next JJ hunk")
    map("[h", function() jj.nav_hunk("prev")  end, "Prev JJ hunk")
    map("]H", function() jj.nav_hunk("last")  end, "Last JJ hunk")
    map("[H", function() jj.nav_hunk("first") end, "First JJ hunk")
    map("<leader>ghp", jj.preview_hunk, "Preview JJ hunk")
    map("<leader>ghr", jj.restore_hunk, "Restore from @-")
  end,
})
```

## Statusline Integration

`jj-signs.nvim` exports a `summary()` function for statusline components:

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

## Highlights

Default highlights link to standard Neovim diff groups so any colorscheme works:

| Group              | Links to          |
|--------------------|-------------------|
| `JJSignsAdd`       | `DiffAdd`         |
| `JJSignsChange`    | `DiffChange`      |
| `JJSignsDelete`    | `DiffDelete`      |
| `JJSignsConflict`  | `DiagnosticError` |
| `JJSigns*Nr`       | `JJSigns*` (numhl variants) |
| `JJSigns*Ln`       | diff groups (linehl variants) |

Override in your config:
```lua
vim.api.nvim_set_hl(0, "JJSignsAdd", { fg = "#00ff00" })
```

## JJ Workspaces

Multiple JJ workspaces (`jj workspace add`) are supported automatically. Each workspace has its
own `@`, and signs reflect whichever workspace owns the file you are editing. No configuration
needed — the plugin detects the workspace root via `jj root` from the file's directory.

If you access files from outside their workspace directory (symlinks, remote mounts, etc.), set
`jj_repo` to the workspace root explicitly:

```lua
require("jj-signs").setup({
  jj_repo = "/path/to/workspace",
})
```

This passes `--repository` to every `jj` invocation, pinning it to the correct workspace.

## What It Does Not Do

- No staging (JJ has no index)
- No line blame (see `jj annotate`)
- No diff for arbitrary revisions (use your `jj.nvim` plugin for that)
- No signs for parent changes — only the current `@`
- No virtual text — signcolumn only

## Credits

Sign rendering, hunk calculation, and navigation logic are adapted from
[**gitsigns.nvim**](https://github.com/lewis6991/gitsigns.nvim) by Lewis Russell,
used under the [MIT License](https://github.com/lewis6991/gitsigns.nvim/blob/main/LICENSE).

## License

MIT
