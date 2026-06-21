--- Statusline buffer variables. Mirrors gitsigns' b:gitsigns_status* vars so
--- lualine / native statuslines read a buffer variable instead of calling a
--- function every redraw. Maintained by init.refresh after each signs.place.

local api    = vim.api
local config = require("jj-signs.config")
local hunks  = require("jj-signs.hunks")

local M = {}

--- Short form of a change_id for display (gitsigns_head equivalent).
--- @param change_id string?
--- @return string
local function short(change_id)
  if not change_id or change_id == "" then return "" end
  return change_id:sub(1, 8)
end

--- Build the status dict from hunks + the @ change_id.
--- @param hunk_list JJSigns.Hunk[]?
--- @param change_id string?
--- @return { added: integer, changed: integer, removed: integer, conflicts: integer, head: string }
function M.build_dict(hunk_list, change_id)
  local s = hunks.get_summary(hunk_list)
  return {
    added     = s.added,
    changed   = s.changed,
    removed   = s.deleted,
    conflicts = s.conflicts,
    head      = short(change_id),
  }
end

--- Format the dict into the b:jjsigns_status string via the configured formatter.
--- @param dict table
--- @return string
function M.format(dict)
  return config.config.status_formatter(dict)
end

--- Populate b:jjsigns_status_dict / b:jjsigns_status / b:jjsigns_head.
--- @param bufnr integer
--- @param hunk_list JJSigns.Hunk[]?
--- @param change_id string?
function M.update(bufnr, hunk_list, change_id)
  if not api.nvim_buf_is_valid(bufnr) then return end
  local dict = M.build_dict(hunk_list, change_id)
  vim.b[bufnr].jjsigns_status_dict = dict
  vim.b[bufnr].jjsigns_status      = M.format(dict)
  vim.b[bufnr].jjsigns_head        = dict.head
end

--- Clear the status vars (on detach).
--- @param bufnr integer
function M.clear(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then return end
  vim.b[bufnr].jjsigns_status_dict = nil
  vim.b[bufnr].jjsigns_status      = nil
  vim.b[bufnr].jjsigns_head        = nil
end

return M
