local api = vim.api

local config     = require("jj-signs.config")
local cache      = require("jj-signs.cache")
local base_cache = require("jj-signs.base_cache")
local jj       = require("jj-signs.jj")
local pipeline = require("jj-signs.pipeline")
local signs    = require("jj-signs.signs")
local hunks    = require("jj-signs.hunks")
local autocmds = require("jj-signs.autocmds")
local watcher  = require("jj-signs.watcher")
local status   = require("jj-signs.status")

local M = {}

--- Global on/off flag. When false, auto-attach (via schedule_refresh) is
--- skipped. Toggled by M.enable / M.disable; read by autocmds.schedule_refresh.
M._enabled = true

--- Bump every known root's op generation so the next refresh re-reads @'s
--- change_id. Called on repo-internal writes that may have changed the op. The
--- op-generation state lives in the watcher module (single canonical instance);
--- see watcher.lua for why init.lua can't own it.
function M.invalidate_op_state()
  watcher.invalidate()
end

--- @param opts JJSigns.Config?
function M.setup(opts)
  config.setup(opts)
  M._initialized = true

  -- Register the :JJSigns command (also registered in plugin/ pre-setup).
  require("jj-signs.cli").create_command()

  if vim.fn.executable(config.config.jj_cmd) == 0 then
    vim.notify("jj-signs: '" .. config.config.jj_cmd .. "' not found in PATH", vim.log.levels.WARN)
    return
  end

  signs.setup_highlights()
  signs.setup()
  autocmds.setup()
end

--- Default buffer-local keymaps, applied when on_attach is nil.
--- Mirrors LazyVim's gitsigns keymap layout so muscle memory transfers.
--- @param bufnr integer
local function default_keymaps(bufnr)
  local function map(mode, key, fn, desc)
    vim.keymap.set(mode, key, fn, { buffer = bufnr, desc = desc, silent = true })
  end

  map("n", "]h",          function() M.nav_hunk("next")  end, "Next JJ hunk")
  map("n", "[h",          function() M.nav_hunk("prev")  end, "Prev JJ hunk")
  map("n", "]H",          function() M.nav_hunk("last")  end, "Last JJ hunk")
  map("n", "[H",          function() M.nav_hunk("first") end, "First JJ hunk")
  map("n", "<leader>ghp", function() M.preview_hunk()        end, "Preview JJ hunk")
  map("n", "<leader>ghP", function() M.preview_hunk_inline() end, "Preview JJ hunk (inline)")
  map("n", "<leader>ghr", function() M.restore_hunk()    end, "Restore JJ hunk from @-")
  map("n", "<leader>ghR", function() M.reset_buffer()    end, "Reset JJ buffer to @-")
  map("n", "<leader>ghd", function() M.diffthis()        end, "Diff this vs @-")
  map("n", "<leader>ghD", function() M.diffthis_rev()    end, "Diff this vs revision…")
  map("n", "<leader>ghb", function() M.blame_line({ full = true }) end, "Blame line (popup)")
  map("n", "<leader>ghB", function() M.blame()           end, "Blame full file")
  map({"x", "o"}, "ih",  function() M.select_hunk(bufnr) end, "Select JJ hunk")
  map("n", "<leader>ghq", function() M.setqflist("attached", { open = true }) end, "JJ hunks → quickfix")
  map("n", "<leader>ghl", function() M.setloclist(0, { open = true })        end, "JJ hunks → loclist")
end

--- Attach to a buffer: detect jj repo, seed cache, apply keymaps, kick off first refresh.
--- @param bufnr integer?
function M.attach(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  if cache.has(bufnr) then return end

  local filepath = api.nvim_buf_get_name(bufnr)
  if filepath == "" then return end

  jj.get_root(filepath, function(root)
    if not root then return end  -- not a jj repo

    cache.set(bufnr, {
      root        = root,
      change_id   = "",
      mtime       = 0,
      hunks       = {},
      dirty       = true,
      dirty_range = nil,
      base_rev    = "@-",
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

    -- Mark the edited region dirty and schedule a refresh. on_lines reports the
    -- changed line span; we union it into entry.dirty_range, which acts as the
    -- "buffer changed since last diff" signal the refresh skip-check reads. (The
    -- refresh itself always re-diffs the whole buffer; see do_buf_diff.)
    api.nvim_buf_attach(bufnr, false, {
      on_lines = function(_, buf, _, first, _last_old, last_new, _)
        local e = cache.get(buf)
        if not e then return true end  -- return true to detach
        -- Union new dirty range with existing dirty range
        if not e.dirty_range then
          e.dirty_range = { first = first, last = last_new }
        else
          e.dirty_range.first = math.min(e.dirty_range.first, first)
          e.dirty_range.last  = math.max(e.dirty_range.last, last_new)
        end
        autocmds.schedule_refresh(buf)
      end,
    })

    watcher.start(root, function()
      -- A new op landed (the watcher already bumped its generation). Invalidate
      -- buffer caches and schedule refreshes; refresh() re-reads @'s change_id.
      cache.invalidate_all_in_root(root)
      for buf, buf_entry in pairs(cache.all()) do
        if buf_entry.root == root then
          autocmds.schedule_refresh(buf)
        end
      end
    end)
  end)
end

--- @param bufnr integer?
function M.detach(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local entry = cache.get(bufnr)
  autocmds.cancel(bufnr)
  signs.clear(bufnr)
  status.clear(bufnr)
  cache.clear(bufnr)

  -- Evict shared base_cache entries no longer referenced by any live buffer.
  local active_keys = {}
  for buf, ent in pairs(cache.all()) do
    if ent.parent_change_id and ent.parent_commit_id then
      local fp = api.nvim_buf_get_name(buf)
      active_keys[base_cache.key(fp, ent.parent_change_id, ent.parent_commit_id, ent.base_rev)] = true
    end
  end
  base_cache.evict_stale(active_keys)

  if entry then
    watcher.stop(entry.root)
  end
end


--- Refresh signs for a buffer: diff its live content against cached base text and
--- place the signs. Delegates to the pipeline module, which owns the coroutine
--- orchestration; the throttled auto-refresh path calls pipeline._refresh_impl
--- directly. Public entry point.
--- @param bufnr integer?
function M.refresh(bufnr)
  pipeline.refresh(bufnr)
end

--- Point a buffer's comparison base at `rev` and force a refresh. Invalidates the
--- cached base content and resolved parent ids so the next refresh re-fetches the
--- file as it exists in `rev`. base_rev defaults to "@-" (parent of @); change_base
--- is the per-buffer escape hatch for "what changed since <rev>" (e.g. a branch point).
--- @param entry JJSigns.CacheEntry
--- @param bufnr integer
--- @param rev string
local function apply_base(bufnr, entry, rev)
  entry.base_rev         = rev
  entry.base_text        = nil
  entry.parent_change_id = nil
  entry.parent_commit_id = nil
  entry.dirty            = true
  entry.dirty_range      = nil
  M.refresh(bufnr)
end

--- Compare a buffer against `rev` instead of the default parent (@-).
--- @param rev string  revision to use as the comparison base
--- @param bufnr integer?  target buffer; defaults to current
function M.change_base(rev, bufnr)
  if not rev or rev == "" then
    vim.notify("jj-signs: change_base requires a revision", vim.log.levels.WARN)
    return
  end
  bufnr = bufnr or api.nvim_get_current_buf()
  local entry = cache.get(bufnr)
  if not entry then return end
  apply_base(bufnr, entry, rev)
end

--- Restore the default comparison base (@-) for a buffer.
--- @param bufnr integer?  target buffer; defaults to current
function M.reset_base(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local entry = cache.get(bufnr)
  if not entry then return end
  apply_base(bufnr, entry, "@-")
end

--- Read-only accessor: a copy of the cached hunks for a buffer. Returns an empty
--- table when the buffer is not attached, so callers never see nil.
--- @param bufnr integer?
--- @return JJSigns.Hunk[]
function M.get_hunks(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local entry = cache.get(bufnr)
  if not entry or not entry.hunks then return {} end
  return vim.deepcopy(entry.hunks)
end

--- Whether jj-signs is attached to a buffer.
--- @param bufnr integer?
--- @return boolean
function M.is_attached(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  return cache.has(bufnr)
end

--- Detach from every attached buffer.
function M.detach_all()
  -- Snapshot keys first: M.detach mutates the cache table as we go.
  local bufs = {}
  for bufnr in pairs(cache.all()) do
    bufs[#bufs + 1] = bufnr
  end
  for _, bufnr in ipairs(bufs) do
    M.detach(bufnr)
  end
end

--- Schedule a refresh for every attached, visible buffer.
function M.refresh_all()
  for bufnr in pairs(cache.all()) do
    if api.nvim_buf_is_valid(bufnr) and #vim.fn.win_findbuf(bufnr) > 0 then
      autocmds.schedule_refresh(bufnr)
    end
  end
end

--- Globally disable jj-signs: detach all buffers and skip auto-attach until
--- M.enable is called.
function M.disable()
  M._enabled = false
  M.detach_all()
end

--- Globally (re-)enable jj-signs and attach to all currently loaded buffers.
function M.enable()
  M._enabled = true
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(bufnr) then
      M.attach(bufnr)
    end
  end
end

--- @param direction "next" | "prev" | "first" | "last"
--- @param opts? { wrap?: boolean, preview?: boolean|"inline", foldopen?: boolean, count?: integer, navigation_message?: boolean }
function M.nav_hunk(direction, opts)
  hunks.nav_hunk(direction, opts)
end

function M.preview_hunk()
  hunks.preview_hunk()
end

--- Inline (virtual-line) preview of the hunk under cursor; no floating window.
function M.preview_hunk_inline()
  hunks.preview_hunk_inline()
end

function M.restore_hunk()
  hunks.restore_hunk(api.nvim_get_current_buf())
end

--- Reset the entire buffer to the comparison base (default @-), discarding all
--- working-copy changes. Buffer-wide counterpart to restore_hunk.
function M.reset_buffer()
  hunks.reset_buffer(api.nvim_get_current_buf())
end

function M.diffthis(rev)
  hunks.diffthis(rev)
end

function M.diffthis_rev()
  hunks.diffthis_rev()
end

--- Popup the full change description for the cursor line. Additive to (and
--- independent of) the inline `current_line_blame` EOL virtual text.
--- @param opts { full?: boolean }|string|nil  CLI passes "full" as a string
function M.blame_line(opts)
  if type(opts) == "string" then
    opts = { full = (opts == "full" or opts == "true") }
  end
  require("jj-signs.blame").blame_line(opts)
end

--- Open a scroll-bound side split blaming the whole file.
function M.blame()
  require("jj-signs.blame").blame()
end

--- @param bufnr integer?
function M.select_hunk(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local entry = cache.get(bufnr)
  if not entry or not entry.hunks then return end

  local lnum = api.nvim_win_get_cursor(0)[1]
  local hunk = hunks.find_hunk(lnum, entry.hunks)
  if not hunk then return end

  local first = math.max(1, hunk.added.start)
  local last  = first + math.max(hunk.added.count, 1) - 1

  vim.cmd("normal! " .. first .. "GV" .. last .. "G")
end

--- Populate the quickfix list with hunks across buffers. Drives list-based
--- navigation and Trouble.nvim. Reads cached hunks only — no jj subprocess.
--- @param target "attached"|integer|string|nil  "attached"/nil = all attached
---   buffers, 0 = current buffer, otherwise a specific bufnr
--- @param opts { open?: boolean, use_loc?: boolean }?
function M.setqflist(target, opts)
  require("jj-signs.qflist").setqflist(target, opts)
end

--- Populate the current window's location list with hunks.
--- @param target "attached"|integer|string|nil  defaults to 0 (current buffer)
--- @param opts { open?: boolean }?
function M.setloclist(target, opts)
  require("jj-signs.qflist").setloclist(target, opts)
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

function M.toggle_current_line_blame()
  config.config.current_line_blame = not config.config.current_line_blame
  if not config.config.current_line_blame then
    local blame = require("jj-signs.blame")
    for _, bufnr in ipairs(api.nvim_list_bufs()) do
      blame.clear(bufnr)
    end
  end
end

--- Re-place signs for every attached buffer from its cached hunks. signs.place
--- re-reads the live config flags (signcolumn/numhl/linehl/word_diff/show_deleted)
--- on each call, so a single reapply propagates any flag flip to all buffers.
function M._reapply_all()
  for bufnr, entry in pairs(cache.all()) do
    if api.nvim_buf_is_valid(bufnr) and entry.hunks then
      signs.place(bufnr, entry.hunks)
    end
  end
end

--- Flip a boolean config flag, or set it to an explicit value when given.
--- @param flag string  key in config.config
--- @param value boolean?  explicit value; nil toggles the current value
--- @return boolean  the new value
local function set_flag(flag, value)
  if value == nil then value = not config.config[flag] end
  config.config[flag] = value
  return value
end

--- Toggle the sign column. Mirrors gitsigns' toggle_signs.
--- @param value boolean?  explicit value; nil toggles
--- @return boolean  the new signcolumn state
function M.toggle_signs(value)
  local v = set_flag("signcolumn", value)
  M._reapply_all()
  return v
end

--- Toggle number-column highlighting. Forces the non-provider extmark path.
--- @param value boolean?  explicit value; nil toggles
--- @return boolean  the new numhl state
function M.toggle_numhl(value)
  local v = set_flag("numhl", value)
  M._reapply_all()
  return v
end

--- Toggle line highlighting. Forces the non-provider extmark path.
--- @param value boolean?  explicit value; nil toggles
--- @return boolean  the new linehl state
function M.toggle_linehl(value)
  local v = set_flag("linehl", value)
  M._reapply_all()
  return v
end

--- Toggle inline word-diff highlighting. signs.place gates place_word_diff.
--- @param value boolean?  explicit value; nil toggles
--- @return boolean  the new word_diff state
function M.toggle_word_diff(value)
  local v = set_flag("word_diff", value)
  M._reapply_all()
  return v
end

--- Toggle virtual-line display of deleted lines. signs.place gates the rendering.
--- @param value boolean?  explicit value; nil toggles
--- @return boolean  the new show_deleted state
function M.toggle_deleted(value)
  local v = set_flag("show_deleted", value)
  M._reapply_all()
  return v
end

return M
