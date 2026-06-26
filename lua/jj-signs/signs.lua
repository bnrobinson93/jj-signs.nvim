--- Sign placement via extmarks.
--- Adapted from gitsigns.nvim (lewis6991/gitsigns.nvim) — MIT License

local api = vim.api
local config = require("jj-signs.config")

local M = {}

local ns = api.nvim_create_namespace("jj-signs")
M.ns = ns

local deleted_ns = api.nvim_create_namespace("jj-signs-deleted")

--- Derive number-column and line hl group names from the base hl group.
--- Convention mirrors gitsigns: JJSignsAdd → JJSignsAddNr / JJSignsAddLn.
--- @param base_hl string
--- @return string numhl, string linehl
local function derive_hls(base_hl)
  -- Strip "JJSigns" prefix to get the type name, e.g. "Add"
  local suffix = base_hl:match("^JJSigns(.+)$") or base_hl
  return "JJSigns" .. suffix .. "Nr", "JJSigns" .. suffix .. "Ln"
end

--- Try each fallback in order; link target to the first one that has a fg color.
--- Mirrors gitsigns' derive() strategy. Since we require nvim 0.10+, `Added` /
--- `Changed` / `Removed` are always defined with proper signcolumn fg colors.
--- @param target   string
--- @param fallbacks string[]
local function derive(target, fallbacks)
  for _, name in ipairs(fallbacks) do
    local hl = api.nvim_get_hl(0, { name = name, link = false })
    if hl.fg then
      api.nvim_set_hl(0, target, { link = name, default = true })
      return
    end
  end
  -- No fallback had fg — link to first anyway so the group exists
  api.nvim_set_hl(0, target, { link = fallbacks[1], default = true })
end

function M.setup_highlights()
  -- Sign-column groups. Fallback chain:
  --   Added/Changed/Removed  — nvim 0.10+ semantic diff groups with signcolumn-ready fg
  --   Diff*                  — universal last resort (bg-only in many themes, but safe)
  derive("JJSignsAdd",    { "Added",   "DiffAdd" })
  derive("JJSignsChange", { "Changed", "DiffChange" })
  derive("JJSignsDelete", { "Removed", "DiffDelete" })
  api.nvim_set_hl(0, "JJSignsConflict", { link = "DiagnosticError", default = true })
  derive("JJSignsTopDelete",    { "Removed", "DiffDelete" })
  derive("JJSignsChangedelete", { "Changed", "DiffChange" })

  -- Number-column variants (numhl)
  derive("JJSignsAddNr",    { "Added",   "DiffAdd" })
  derive("JJSignsChangeNr", { "Changed", "DiffChange" })
  derive("JJSignsDeleteNr", { "Removed", "DiffDelete" })
  api.nvim_set_hl(0, "JJSignsConflictNr", { link = "DiagnosticError", default = true })
  derive("JJSignsTopDeleteNr",    { "Removed", "DiffDelete" })
  derive("JJSignsChangedeleteNr", { "Changed", "DiffChange" })

  -- Line-highlight variants (linehl) — bg-based, Diff* is appropriate here
  api.nvim_set_hl(0, "JJSignsAddLn",          { link = "DiffAdd",         default = true })
  api.nvim_set_hl(0, "JJSignsChangeLn",        { link = "DiffChange",      default = true })
  api.nvim_set_hl(0, "JJSignsDeleteLn",        { link = "DiffDelete",      default = true })
  api.nvim_set_hl(0, "JJSignsConflictLn",      { link = "DiagnosticError", default = true })
  api.nvim_set_hl(0, "JJSignsTopDeleteLn",     { link = "DiffDelete",      default = true })
  api.nvim_set_hl(0, "JJSignsChangeDeleteLn",  { link = "DiffChange",      default = true })

  -- Conflict region tints (parse_conflict_regions roles). Linked to standard diff
  -- groups so they read correctly in any colorscheme; override to taste.
  api.nvim_set_hl(0, "JJSignsConflictMarker", { link = "DiagnosticError", default = true })
  api.nvim_set_hl(0, "JJSignsConflictOurs",   { link = "DiffAdd",         default = true })
  api.nvim_set_hl(0, "JJSignsConflictBase",   { link = "DiffChange",      default = true })
  api.nvim_set_hl(0, "JJSignsConflictTheirs", { link = "DiffText",        default = true })

  api.nvim_set_hl(0, "JJSignsCurrentLineBlame", { link = "NonText", default = true })

  derive("JJSignsAddWord",    { "Added",   "DiffAdd" })
  derive("JJSignsChangeWord", { "Changed", "DiffChange" })
  derive("JJSignsDeleteWord", { "Removed", "DiffDelete" })

  api.nvim_set_hl(0, "JJSignsDeleteVirtLn", { link = "DiffDelete", default = true })
end

local function build_hunk_index(hunks)
  local index = {}
  for i, hunk in ipairs(hunks) do
    local next_hunk = hunks[i + 1]
    local sign_type = hunk.type

    if hunk.type == "delete" and hunk.added.start == 0 then
      sign_type = "topdelete"
    elseif hunk.type == "change" and (
      hunk.removed.count > hunk.added.count
      or (next_hunk and next_hunk.type == "delete"
          and next_hunk.added.start == hunk.added.start + hunk.added.count - 1)
    ) then
      sign_type = "changedelete"
    end

    local start_l = hunk.added.start == 0 and 1 or hunk.added.start
    local end_l   = (hunk.type == "delete" or hunk.type == "topdelete") and start_l or hunk.vend

    -- Build a set of exact changed line numbers to avoid signing context lines
    -- within merged hunks. Nil means "no filtering" (delete/topdelete, conflicts).
    local lnum_set = nil
    local lnums = hunk.added.lnums
    if lnums and #lnums > 0 then
      lnum_set = {}
      for _, l in ipairs(lnums) do lnum_set[l] = true end
    end

    index[#index + 1] = { start = start_l, vend = end_l, sign_type = sign_type, lnum_set = lnum_set }
  end
  table.sort(index, function(a, b) return a.start < b.start end)
  return index
end

local function find_sign_at(lnum, index)
  local lo, hi = 1, #index
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local entry = index[mid]
    if lnum < entry.start then
      hi = mid - 1
    elseif lnum > entry.vend then
      lo = mid + 1
    else
      -- Skip context lines within merged hunks
      if entry.lnum_set and not entry.lnum_set[lnum] then return nil end
      return entry
    end
  end
end

M._build_hunk_index = build_hunk_index
M._find_sign_at     = find_sign_at

local provider_registered = false

function M.setup()
  if provider_registered then return end
  provider_registered = true

  local cache = require("jj-signs.cache")

  api.nvim_set_decoration_provider(ns, {
    on_win = function(_, _, bufnr, _, _)
      if not cache.get(bufnr) then return false end
      local entry = cache.get(bufnr)
      if not entry or not entry.hunk_index then return false end
      return true
    end,
    on_line = function(_, _, bufnr, lnum)
      if not require("jj-signs.config").config.use_decoration_provider then return end
      local entry = require("jj-signs.cache").get(bufnr)
      if not entry or not entry.hunk_index then return end

      local sign_entry = find_sign_at(lnum + 1, entry.hunk_index)
      if not sign_entry then return end

      local sign_cfg = config.config.signs[sign_entry.sign_type]
      if not sign_cfg then return end

      pcall(api.nvim_buf_set_extmark, bufnr, ns, lnum, 0, {
        sign_text     = config.config.signcolumn and sign_cfg.text or "",
        sign_hl_group = sign_cfg.hl,
        priority      = config.config.sign_priority,
      })
    end,
  })
end

local MAX_DELETED_LINES = 20

local function place_deleted_lines(bufnr, hunks)
  api.nvim_buf_clear_namespace(bufnr, deleted_ns, 0, -1)
  local line_count = api.nvim_buf_line_count(bufnr)

  for _, hunk in ipairs(hunks) do
    if (hunk.type == "delete" or hunk.type == "change") and #hunk.removed.lines > 0 then
      local lnum
      if hunk.type == "delete" then
        lnum = hunk.added.start == 0 and 0 or hunk.added.start
      else
        lnum = hunk.added.start - 1
      end
      lnum = math.min(lnum, line_count - 1)

      local display_lines = {}
      for i, l in ipairs(hunk.removed.lines) do
        if i > MAX_DELETED_LINES then break end
        display_lines[#display_lines+1] = { { l, "JJSignsDeleteVirtLn" } }
      end

      pcall(api.nvim_buf_set_extmark, bufnr, deleted_ns, math.max(lnum, 0), 0, {
        virt_lines       = display_lines,
        virt_lines_above = true,
      })
    end
  end
end

--- Force a full invalidating redraw on every window showing this buffer so the
--- decoration provider's on_line callback re-evaluates from the current
--- entry.hunk_index immediately, rather than on the next natural redraw.
--- @param bufnr integer
local function redraw_buf(bufnr)
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == bufnr then
      pcall(api.nvim__redraw, { win = win, valid = false })
    end
  end
end

--- @param bufnr integer
function M.clear(bufnr)
  api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  api.nvim_buf_clear_namespace(bufnr, deleted_ns, 0, -1)
  require("jj-signs.word_diff").clear_word_diff(bufnr)

  -- Reset the decoration provider's source of truth. on_line draws persistent
  -- sign marks from entry.hunk_index; if we clear the namespace but leave a stale
  -- hunk_index, the next redraw repaints the very signs we just cleared. Drop the
  -- index and request a redraw so the cleared state actually renders.
  local entry = require("jj-signs.cache").get(bufnr)
  if entry then
    entry.hunk_index = nil
  end
  redraw_buf(bufnr)
end

local CONFLICT_ROLE_HL = {
  marker = "JJSignsConflictMarker",
  ours   = "JJSignsConflictOurs",
  base   = "JJSignsConflictBase",
  theirs = "JJSignsConflictTheirs",
}

--- Tint the ours/base/theirs/marker regions inside one conflict block. Reads the
--- block's lines from the buffer, classifies them per jj marker style via
--- diff.parse_conflict_regions, and lays a line-bg extmark on each. Placed in the
--- main `ns` so M.clear() removes them alongside the signs.
--- @param bufnr integer
--- @param hunk JJSigns.Hunk
--- @param line_count integer
local function place_conflict_regions(bufnr, hunk, line_count)
  local first = math.max(hunk.added.start, 1)
  local last = math.min(hunk.vend, line_count)
  if last < first then return end

  local lines = api.nvim_buf_get_lines(bufnr, first - 1, last, false)
  local regions = require("jj-signs.diff").parse_conflict_regions(lines, first)
  for _, r in ipairs(regions) do
    local hl = CONFLICT_ROLE_HL[r.role]
    if hl then
      pcall(api.nvim_buf_set_extmark, bufnr, ns, r.lnum - 1, 0, {
        line_hl_group = hl,
        priority      = config.config.sign_priority,
      })
    end
  end
end

--- @param bufnr integer
--- @param hunks JJSigns.Hunk[]
function M.place(bufnr, hunks)
  M.clear(bufnr)

  local line_count = api.nvim_buf_line_count(bufnr)
  local use_provider = config.config.use_decoration_provider

  local hunk_index = build_hunk_index(hunks)
  local entry = require("jj-signs.cache").get(bufnr)
  if entry then
    entry.hunk_index = hunk_index
  end

  for i, hunk in ipairs(hunks) do
    local next_hunk = hunks[i + 1]
    local sign_type = hunk.type

    if hunk.type == "delete" and hunk.added.start == 0 then
      sign_type = "topdelete"
    elseif hunk.type == "change" and (
      hunk.removed.count > hunk.added.count
      or (next_hunk and next_hunk.type == "delete"
          and next_hunk.added.start == hunk.added.start + hunk.added.count - 1)
    ) then
      sign_type = "changedelete"
    end

    local function place(lnum, stype)
      if use_provider and not config.config.numhl and not config.config.linehl then
        return
      end
      local sign_cfg = config.config.signs[stype]
      if not sign_cfg then return end
      local numhl_grp, linehl_grp = derive_hls(sign_cfg.hl)
      local opts = {
        id            = lnum,
        priority      = config.config.sign_priority,
        sign_text     = (not use_provider and config.config.signcolumn) and sign_cfg.text or "",
        sign_hl_group = sign_cfg.hl,
      }
      if config.config.numhl then opts.number_hl_group = numhl_grp end
      if config.config.linehl then opts.line_hl_group = linehl_grp end
      pcall(api.nvim_buf_set_extmark, bufnr, ns, lnum - 1, 0, opts)
    end

    if sign_type == "add" or sign_type == "change" or sign_type == "changedelete" then
      local lnums = hunk.added.lnums
      if lnums then
        for _, l in ipairs(lnums) do
          if l >= 1 and l <= line_count then place(l, sign_type) end
        end
      else
        for l = hunk.added.start, hunk.vend do
          if l >= 1 and l <= line_count then place(l, sign_type) end
        end
      end
    elseif sign_type == "delete" then
      local lnum = math.min(hunk.added.start, line_count)
      if lnum >= 1 then place(lnum, "delete") end
    elseif sign_type == "topdelete" then
      local lnum = math.min(1, line_count)
      if lnum >= 1 then place(lnum, "topdelete") end
    elseif sign_type == "conflict" then
      for l = hunk.added.start, hunk.vend do
        if l >= 1 and l <= line_count then place(l, "conflict") end
      end
      if config.config.conflict_hl then
        place_conflict_regions(bufnr, hunk, line_count)
      end
    end
  end

  if config.config.show_deleted then
    place_deleted_lines(bufnr, hunks)
  end

  if config.config.word_diff then
    require("jj-signs.word_diff").place_word_diff(bufnr, hunks, entry and entry.change_id)
  end

  -- When using the decoration provider, on_line draws signs per render pass
  -- rather than via M.place directly. Nothing marks the buffer dirty, so signs
  -- only appear on the next natural redraw (cursor move). Force a full
  -- invalidating redraw so on_line fires immediately after sign state changes.
  if use_provider then
    redraw_buf(bufnr)
  end
end

return M
