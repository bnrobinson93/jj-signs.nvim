# diffthis

## What

Open a diff view comparing the current file against its parent in `@`. Mirrors gitsigns' `diffthis` which opens a `vimdiff` split against the git index/HEAD version.

```
<leader>ghd   — diff current file against @-
<leader>ghD   — diff against a specific revision (prompted)
```

---

## JJ Command

Get file content at parent revision:

```
jj file show --revision @- -- <filepath>
```

This outputs the raw file content at `@-`. Write to a temp file, open in vimdiff.

---

## Implementation

### Simple approach (matches gitsigns default)

```lua
function M.diffthis(rev)
  rev = rev or "@-"
  local filepath = api.nvim_buf_get_name(0)
  local entry = cache.get(api.nvim_get_current_buf())
  if not entry then return end

  -- Get file content at revision
  vim.system(
    jj({ "file", "show", "--revision", rev, "--", filepath }),
    { text = true, cwd = entry.root },
    function(result)
      if result.code ~= 0 then
        vim.notify("jj-signs: could not get file at " .. rev, vim.log.levels.ERROR)
        return
      end
      vim.schedule(function()
        -- Write to temp file
        local tmp = vim.fn.tempname()
        local f = io.open(tmp, "w")
        if f then
          f:write(result.stdout)
          f:close()
        end
        -- Open vimdiff
        vim.cmd("vert diffsplit " .. vim.fn.fnameescape(tmp))
        -- Mark temp buffer for cleanup on close
        local tmpbuf = api.nvim_get_current_buf()
        api.nvim_buf_set_option(tmpbuf, "bufhidden", "wipe")
        api.nvim_buf_set_name(tmpbuf, rev .. ":" .. vim.fn.fnamemodify(filepath, ":t"))
        vim.bo[tmpbuf].modifiable = false
      end)
    end
  )
end
```

### Revision prompt variant

`diffthis_rev()` — `vim.ui.input` to ask for revision, then calls `diffthis(rev)`.

---

## Config

No new config keys needed. Uses existing `jj_cmd` / `jj_repo`.

Optional: `diff_opts.vertical = true` — already in gitsigns' schema, can mirror.

---

## Keymaps (added to default_keymaps in init.lua)

```lua
map("<leader>ghd", function() M.diffthis()     end, "Diff this vs @-")
map("<leader>ghD", function() M.diffthis_rev() end, "Diff this vs revision…")
```

---

## JJ vs Git Difference

gitsigns compares against git index (staged state) by default, or HEAD with `~`. We compare against `@-` (parent change) by default, with revision prompt for `<leader>ghD`. The concept maps cleanly — parent change is the JJ equivalent of HEAD for this purpose.

---

## Changes Required

| File | Change |
|------|--------|
| `hunks.lua` | Add `diffthis(rev)` + `diffthis_rev()` |
| `init.lua` | Expose both on public API, add to `default_keymaps` |

---

## Size Estimate

~60 lines in `hunks.lua`. No new module needed.
