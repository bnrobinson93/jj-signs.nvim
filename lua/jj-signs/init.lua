local api = vim.api

local config   = require("jj-signs.config")
local cache    = require("jj-signs.cache")
local diff_mod = require("jj-signs.diff")
local signs    = require("jj-signs.signs")
local hunks    = require("jj-signs.hunks")
local autocmds = require("jj-signs.autocmds")

local M = {}

--- @param opts JJSigns.Config?
function M.setup(opts)
  config.setup(opts)

  if vim.fn.executable(config.config.jj_cmd) == 0 then
    vim.notify("jj-signs: '" .. config.config.jj_cmd .. "' not found in PATH", vim.log.levels.WARN)
    return
  end

  signs.setup_highlights()
  autocmds.setup()
end

--- Default buffer-local keymaps, applied when on_attach is nil.
--- Mirrors LazyVim's gitsigns keymap layout so muscle memory transfers.
--- @param bufnr integer
local function default_keymaps(bufnr)
  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = bufnr, desc = desc, silent = true })
  end

  map("]h",          function() M.nav_hunk("next")  end, "Next JJ hunk")
  map("[h",          function() M.nav_hunk("prev")  end, "Prev JJ hunk")
  map("]H",          function() M.nav_hunk("last")  end, "Last JJ hunk")
  map("[H",          function() M.nav_hunk("first") end, "First JJ hunk")
  map("<leader>ghp", function() M.preview_hunk()    end, "Preview JJ hunk")
  map("<leader>ghr", function() M.restore_hunk()    end, "Restore JJ hunk from @-")
end

--- Attach to a buffer: detect jj repo, seed cache, apply keymaps, kick off first refresh.
--- @param bufnr integer?
function M.attach(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  if cache.has(bufnr) then return end

  local filepath = api.nvim_buf_get_name(bufnr)
  if filepath == "" then return end

  diff_mod.get_root(filepath, function(root)
    if not root then return end  -- not a jj repo

    cache.set(bufnr, {
      root      = root,
      change_id = "",
      mtime     = 0,
      hunks     = {},
      dirty     = true,
    })

    -- Apply keymaps: user-supplied on_attach, or built-in defaults
    local on_attach = config.config.on_attach
    if on_attach then
      if on_attach(bufnr) == false then
        cache.clear(bufnr)
        return
      end
    else
      default_keymaps(bufnr)
    end

    M.refresh(bufnr)
  end)
end

--- @param bufnr integer?
function M.detach(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  autocmds.cancel(bufnr)
  signs.clear(bufnr)
  cache.clear(bufnr)
end

--- Refresh signs for a buffer. Checks change_id + mtime cache before running jj diff.
--- @param bufnr integer?
function M.refresh(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()

  if not api.nvim_buf_is_valid(bufnr) then return end

  local filepath = api.nvim_buf_get_name(bufnr)
  if filepath == "" then return end

  if not cache.has(bufnr) then
    M.attach(bufnr)
    return
  end

  local entry = cache.get(bufnr)
  if not entry then return end

  diff_mod.get_change_id(entry.root, function(new_change_id)
    if not new_change_id then return end

    local stat = (vim.uv or vim.loop).fs_stat(filepath)
    local new_mtime = stat and stat.mtime.sec or 0

    if not entry.dirty
      and new_change_id == entry.change_id
      and new_mtime == entry.mtime
    then
      return
    end

    diff_mod.run_diff(filepath, entry.root, function(diff_hunks)
      if not diff_hunks then
        signs.clear(bufnr)
        return
      end

      if not api.nvim_buf_is_valid(bufnr) then return end

      local conflict_hunks = diff_mod.find_conflicts(bufnr)
      local merged = diff_mod.merge_hunks(diff_hunks, conflict_hunks)

      signs.place(bufnr, merged)

      cache.set(bufnr, {
        root      = entry.root,
        change_id = new_change_id,
        mtime     = new_mtime,
        hunks     = merged,
        dirty     = false,
      })
    end)
  end)
end

--- @param direction "next" | "prev" | "first" | "last"
function M.nav_hunk(direction)
  hunks.nav_hunk(direction)
end

function M.preview_hunk()
  hunks.preview_hunk()
end

function M.restore_hunk()
  hunks.restore_hunk()
end

--- Summary for statusline components.
--- @return { added: integer, changed: integer, deleted: integer, conflicts: integer }
function M.summary()
  local bufnr = api.nvim_get_current_buf()
  local entry = cache.get(bufnr)
  if not entry then
    return { added = 0, changed = 0, deleted = 0, conflicts = 0 }
  end
  return hunks.get_summary(entry.hunks)
end

return M
