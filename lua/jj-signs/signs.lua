--- Sign placement via extmarks.
--- Adapted from gitsigns.nvim (lewis6991/gitsigns.nvim) — MIT License

local api = vim.api
local config = require("jj-signs.config")

local M = {}

local ns = api.nvim_create_namespace("jj-signs")
M.ns = ns

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

  -- Number-column variants (numhl)
  derive("JJSignsAddNr",    { "Added",   "DiffAdd" })
  derive("JJSignsChangeNr", { "Changed", "DiffChange" })
  derive("JJSignsDeleteNr", { "Removed", "DiffDelete" })
  api.nvim_set_hl(0, "JJSignsConflictNr", { link = "DiagnosticError", default = true })

  -- Line-highlight variants (linehl) — bg-based, Diff* is appropriate here
  api.nvim_set_hl(0, "JJSignsAddLn",      { link = "DiffAdd",         default = true })
  api.nvim_set_hl(0, "JJSignsChangeLn",   { link = "DiffChange",      default = true })
  api.nvim_set_hl(0, "JJSignsDeleteLn",   { link = "DiffDelete",      default = true })
  api.nvim_set_hl(0, "JJSignsConflictLn", { link = "DiagnosticError", default = true })
end

--- @param bufnr integer
function M.clear(bufnr)
  api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
end

--- Place a single sign extmark.
--- @param bufnr integer
--- @param lnum  integer  1-indexed
--- @param type  JJSigns.HunkType
local function place_sign(bufnr, lnum, type)
  local sign_cfg = config.config.signs[type]
  if not sign_cfg then return end

  local numhl_grp, linehl_grp = derive_hls(sign_cfg.hl)

  local opts = {
    id            = lnum,
    priority      = config.config.sign_priority,
    sign_text     = config.config.signcolumn and sign_cfg.text or "",
    sign_hl_group = sign_cfg.hl,
  }
  if config.config.numhl then
    opts.number_hl_group = numhl_grp
  end
  if config.config.linehl then
    opts.line_hl_group = linehl_grp
  end

  local ok, _ = pcall(api.nvim_buf_set_extmark, bufnr, ns, lnum - 1, 0, opts)
  if not ok then end -- non-fatal
end

--- @param bufnr integer
--- @param hunks JJSigns.Hunk[]
function M.place(bufnr, hunks)
  M.clear(bufnr)

  local line_count = api.nvim_buf_line_count(bufnr)

  for _, hunk in ipairs(hunks) do
    if hunk.type == "add" then
      for l = hunk.added.start, hunk.vend do
        if l >= 1 and l <= line_count then
          place_sign(bufnr, l, "add")
        end
      end

    elseif hunk.type == "change" then
      for l = hunk.added.start, hunk.vend do
        if l >= 1 and l <= line_count then
          place_sign(bufnr, l, "change")
        end
      end

    elseif hunk.type == "delete" then
      -- sign at line before deletion point; topdelete (start==0) goes to line 1
      local lnum = hunk.added.start == 0 and 1 or hunk.added.start
      lnum = math.min(lnum, line_count)
      if lnum >= 1 then
        place_sign(bufnr, lnum, "delete")
      end

    elseif hunk.type == "conflict" then
      for l = hunk.added.start, hunk.vend do
        if l >= 1 and l <= line_count then
          place_sign(bufnr, l, "conflict")
        end
      end
    end
  end
end

return M
