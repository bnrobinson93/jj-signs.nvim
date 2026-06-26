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

Conflicts are detected and tinted by region (ours/base/theirs) across all three
jj marker styles — `diff` (default), `snapshot`, and `git` (diff3). Disable the
region tint with `conflict_hl = false` to keep just the `╪` sign.

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
  conflict_hl     = true,    -- tint ours/base/theirs regions inside conflicts
  max_file_length = 40000,
  sign_priority   = 6,
  use_decoration_provider = true,  -- render signs lazily for visible lines only

  -- Floating preview_hunk() window appearance. preview_hunk_inline() ignores
  -- this (it draws virtual lines in-buffer, no float).
  preview_config = {
    border   = "rounded",
    style    = "minimal",
    relative = "cursor",
    row      = 1,
    col      = 0,
  },
  -- nav_hunk() defaults; each is overridable per call via the opts argument.
  nav = {
    wrap               = true,   -- wrap around buffer ends
    navigation_message = true,   -- echo "Hunk N of M" after a jump
    foldopen           = true,   -- open folds at the destination
    preview            = false,  -- true = float, "inline" = virtual lines
  },

  -- vim.diff()/xdiff tuning, mirroring gitsigns' diff_opts. Affects how hunks
  -- are computed and aligned. indent_heuristic and linematch default on (as in
  -- gitsigns / Neovim's diffopt) for nicer hunk boundaries and tighter changes.
  diff_opts = {
    algorithm                = "myers", -- "myers" | "minimal" | "patience" | "histogram"
    indent_heuristic         = true,    -- shift hunk boundaries to align with indentation
    linematch                = 60,       -- integer: second-stage line matching within hunks (false = off)
    ignore_whitespace        = false,   -- ignore all whitespace
    ignore_whitespace_change = false,   -- ignore changes in whitespace amount
  },

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
| `<leader>ghP`   | n       | Preview hunk inline (virtual lines)     |
| `<leader>ghr`   | n       | Restore hunk to `@-` state             |
| `<leader>ghR`   | n       | Reset whole buffer to `@-` state       |
| `<leader>ghd`   | n       | Diff current file vs `@-` in vimdiff   |
| `<leader>ghD`   | n       | Diff vs a prompted revision             |
| `<leader>ghb`   | n       | Blame line: change description popup    |
| `<leader>ghB`   | n       | Blame full file in a side split         |
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
    map("n", "<leader>ghR", jj.reset_buffer,                    "Reset buffer to @-")
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

### On-demand blame popup and full-file view

Two **additive** blame modes complement (they do **not** replace) the inline
`current_line_blame` virtual text above. All three share the same cached
`jj annotate` data but render independently — you can leave `current_line_blame`
off and still use these on demand.

| Function | Keymap | What it does |
|----------|--------|--------------|
| `blame_line(opts?)` | `<leader>ghb` | Float showing the full change description for the cursor line, sourced from `jj show`. `opts.full` (default in the keymap) includes the diff; pass `{ full = false }` for the message only. Closes on cursor move. |
| `blame()` | `<leader>ghB` | Opens a left side split annotating every line with `change_id • author • date`, scroll- and cursor-bound to the source window. Press `q` to close. |

```lua
require("jj-signs").blame_line()              -- message-only popup
require("jj-signs").blame_line({ full = true })  -- popup with full diff
require("jj-signs").blame()                    -- full-file blame split
```

These are independent of `current_line_blame`: the inline EOL blame stays
exactly as configured; `blame_line`/`blame` add an on-demand popup and side
view without changing it.

## Statusline Integration

jj-signs maintains buffer-local variables (refreshed on every redraw of signs),
mirroring gitsigns' `b:gitsigns_status*`:

| Variable | Contents |
|----------|----------|
| `b:jjsigns_status_dict` | `{ added, changed, removed, conflicts, head }` |
| `b:jjsigns_status`      | Formatted string, e.g. `"+3 ~1 -2"` (zero parts omitted) |
| `b:jjsigns_head`        | Short `change_id` of `@` |

Read the variable instead of calling a function each redraw:

```lua
-- lualine component
{
  function()
    return vim.b.jjsigns_status or ""
  end,
  cond = function()
    local d = vim.b.jjsigns_status_dict
    return d ~= nil and (d.added + d.changed + d.removed + d.conflicts) > 0
  end,
}
```

The `b:jjsigns_status` string is built by the configurable `status_formatter`
(default `"+N ~N -N"`, omitting any zero count):

```lua
require("jj-signs").setup({
  status_formatter = function(d)
    local parts = {}
    if (d.added   or 0) > 0 then parts[#parts + 1] = "+" .. d.added   end
    if (d.changed or 0) > 0 then parts[#parts + 1] = "~" .. d.changed end
    if (d.removed or 0) > 0 then parts[#parts + 1] = "-" .. d.removed end
    return table.concat(parts, " ")
  end,
})
```

## Public API

| Function | Description |
|----------|-------------|
| `setup(opts)` | Initialize with config |
| `attach(bufnr?)` | Attach to buffer (called automatically) |
| `detach(bufnr?)` | Detach and clear signs |
| `refresh(bufnr?)` | Force re-check change_id + mtime and redraw |
| `refresh_all()` | Schedule a refresh for every attached, visible buffer |
| `detach_all()` | Detach from every attached buffer |
| `enable()` | Globally enable and re-attach all loaded buffers |
| `disable()` | Globally disable: detach all and skip auto-attach |
| `is_attached(bufnr?)` | Whether jj-signs is attached to the buffer |
| `get_hunks(bufnr?)` | Copy of the cached hunks (read-only accessor) |
| `nav_hunk(direction, opts?)` | Navigate: `"next"` `"prev"` `"first"` `"last"`. `opts` (all optional): `wrap`, `preview`, `foldopen`, `count`, `navigation_message` — see below |
| `preview_hunk()` | Float showing removed/added lines |
| `preview_hunk_inline()` | Inline preview: removed lines as dimmed virtual lines above the hunk + highlighted added lines, cleared on the next cursor move (no float) |
| `restore_hunk()` | Replace hunk lines with `@-` content via buffer API |
| `reset_buffer()` | Reset the whole buffer to `@-` content (discards all working-copy changes) |
| `select_hunk(bufnr?)` | Set visual selection to hunk lines |
| `diffthis(rev?)` | Open vimdiff vs `rev` (default `"@-"`) |
| `diffthis_rev()` | Prompt for revision, then open vimdiff |
| `change_base(rev, bufnr?)` | Compare the buffer against `rev` instead of the default parent (`@-`). Invalidates the cached base and forces a refresh, so signs show "what changed since `rev`" (e.g. a branch point). Per-buffer. |
| `reset_base(bufnr?)` | Restore the default comparison base (`@-`) for the buffer. |
| `blame_line(opts?)` | Popup the cursor line's change description (`opts.full` adds the diff) |
| `blame()` | Full-file blame in a scroll-bound side split |
| `toggle_current_line_blame()` | Toggle inline blame |
| `toggle_signs(value?)` | Toggle the sign column; returns new state |
| `toggle_numhl(value?)` | Toggle number-column highlighting; returns new state |
| `toggle_linehl(value?)` | Toggle line highlighting; returns new state |
| `toggle_word_diff(value?)` | Toggle inline word-diff; returns new state |
| `toggle_deleted(value?)` | Toggle deleted-line virtual lines; returns new state |
| `setqflist(target?, opts?)` | Send hunks to the quickfix list (see below) |
| `setloclist(target?, opts?)` | Send hunks to the current window's location list |
| `summary()` | Return `{ added, changed, deleted, conflicts }` |

### `nav_hunk` options

`nav_hunk(direction, opts?)` accepts a per-call `opts` table; each key falls back
to the matching `nav` config default (see [Configuration](#configuration)).

| Key | Default | Effect |
| --- | ------- | ------ |
| `wrap` | `true` | Wrap around the ends of the buffer when there is no hunk in `direction`. |
| `count` | `1` | Skip `count` hunks instead of one (no-op for `"first"`/`"last"`). |
| `foldopen` | `true` | Run `normal! zv` at the destination to open any closed fold. |
| `navigation_message` | `true` | Echo `"Hunk N of M"` after the jump. Set `false` to suppress. |
| `preview` | `false` | Auto-open a preview after the jump: `true` = float (`preview_hunk`), `"inline"` = virtual lines (`preview_hunk_inline`). |

```lua
local jj = require("jj-signs")
jj.nav_hunk("next", { count = 2, preview = "inline", wrap = false })
```

## Commands

`:JJSigns <action> [args...]` runs any of the public actions from the command
line — the command-line equivalent of the Lua API table above. The action name
tab-completes:

```vim
:JJSigns <Tab>            " list actions
:JJSigns nav_hunk next    " == require("jj-signs").nav_hunk("next")
:JJSigns nav_hunk prev
:JJSigns diffthis @--     " == require("jj-signs").diffthis("@--")
:JJSigns change_base main " compare this buffer against 'main' instead of @-
:JJSigns reset_base       " back to the default @- base
:JJSigns preview_hunk
:JJSigns preview_hunk_inline
:JJSigns restore_hunk
:JJSigns reset_buffer      " reset whole buffer to @- (discards changes)
:JJSigns blame_line full   " popup with diff; omit 'full' for message-only
:JJSigns blame             " full-file blame split
:JJSigns refresh
:JJSigns toggle_current_line_blame
:JJSigns toggle_signs
:JJSigns toggle_numhl
:JJSigns toggle_linehl
:JJSigns toggle_word_diff
:JJSigns toggle_deleted
:JJSigns setqflist attached " hunks across all buffers → quickfix
:JJSigns setloclist         " current buffer hunks → location list
```

Each `toggle_*` flips the matching config flag and re-renders all attached
buffers. They return the new boolean (gitsigns convention) and accept an
optional explicit value, e.g. `require("jj-signs").toggle_signs(false)`.

Positional args after the action are forwarded to the function (e.g.
`nav_hunk next`, `diffthis @--`). Available actions: `nav_hunk`, `preview_hunk`,
`restore_hunk`, `reset_buffer`, `diffthis`, `diffthis_rev`, `change_base`, `reset_base`, `blame_line`, `blame`, `select_hunk`, `refresh`,
`refresh_all`, `attach`, `detach`, `detach_all`, `enable`, `disable`,
`get_hunks`, `is_attached`, `toggle_current_line_blame`, `toggle_signs`,
`toggle_numhl`, `toggle_linehl`, `toggle_word_diff`, `toggle_deleted`,
`setqflist`, `setloclist`.

The command is registered before `setup()` runs; invoking it lazily initializes
jj-signs with defaults if you have not called `setup()` yet.

## Quickfix / loclist

Collect hunks across buffers into the quickfix or location list for list-driven
navigation (and [Trouble.nvim](https://github.com/folke/trouble.nvim)):

```lua
require("jj-signs").setqflist("attached", { open = true })  -- all attached buffers → quickfix
require("jj-signs").setqflist(0)                              -- current buffer only
require("jj-signs").setloclist(0, { open = true })           -- current buffer → loclist
```

The `target` selects which buffers contribute hunks:

| `target` | Hunks from |
|----------|------------|
| `"attached"` / `nil` | every attached buffer |
| `0` | the current buffer |
| a `bufnr` | that specific buffer |

`opts.open` opens the list after populating it (`:copen` / `:lopen`). For
`setqflist`, `opts.use_loc` routes to the location list instead — `setloclist`
is the thin wrapper that sets it. Items are built straight from cached hunks, so
**no `jj` subprocess runs** and unsaved buffers are included from their live
in-buffer diff. Each item carries `{ bufnr, lnum = hunk.added.start, text =
"<type> <hunk header>" }`.

Default keymaps: `<leader>ghq` (quickfix, all buffers) and `<leader>ghl`
(loclist, current buffer). Also reachable as `:JJSigns setqflist attached` and
`:JJSigns setloclist`.

**Trouble.nvim**: after `setqflist`, open `:Trouble qflist` (or `:Trouble
loclist` after `setloclist`) to browse the hunks in Trouble's UI.

## Highlights

Default highlight groups link to standard Neovim diff groups so any colorscheme works:

| Group                    | Links to          | Purpose |
|--------------------------|-------------------|---------|
| `JJSignsAdd`             | `Added` / `DiffAdd`    | Added lines |
| `JJSignsChange`          | `Changed` / `DiffChange` | Changed lines |
| `JJSignsDelete`          | `Removed` / `DiffDelete` | Deleted lines |
| `JJSignsTopDelete`       | `Removed` / `DiffDelete` | Deletion at file top |
| `JJSignsChangedelete`    | `Changed` / `DiffChange` | Change that shrinks |
| `JJSignsConflict`        | `DiagnosticError` | Conflict sign |
| `JJSignsConflictMarker`  | `DiagnosticError` | Conflict fence/separator lines |
| `JJSignsConflictOurs`    | `DiffAdd`         | Conflict region: first side (ours) |
| `JJSignsConflictBase`    | `DiffChange`      | Conflict region: merge base |
| `JJSignsConflictTheirs`  | `DiffText`        | Conflict region: last side (theirs) |
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
- Default base is `@` vs its parent (`@-`); use `change_base <rev>` to compare against an arbitrary revision per buffer
- No hunk-level CLI operations — restore uses the buffer API, diff uses a temp file

## Troubleshooting / Docs

Run a health check to diagnose a missing/old `jj`, an unsupported Neovim
version, an invalid `jj_repo`, or to see how many buffers are attached:

```vim
:checkhealth jj-signs
```

Full documentation ships as vimdoc:

```vim
:help jj-signs
```

Plugin managers generate help tags automatically. If `:help jj-signs` reports
no tags, generate them once with `:helptags doc/` (or `:helptags ALL`) from the
plugin directory.

## Credits

Sign rendering, hunk calculation, and navigation logic are adapted from
[**gitsigns.nvim**](https://github.com/lewis6991/gitsigns.nvim) by Lewis Russell,
used under the [MIT License](https://github.com/lewis6991/gitsigns.nvim/blob/main/LICENSE).

## License

MIT
