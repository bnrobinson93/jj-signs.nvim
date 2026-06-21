--- Quickfix / location list population from cached hunks. Mirrors gitsigns'
--- setqflist/setloclist so hunks across buffers can drive list-based navigation
--- (and Trouble.nvim). Reads only the cache — no jj subprocess — so unsaved and
--- clean buffers are handled identically from entry.hunks.

local api   = vim.api
local cache = require("jj-signs.cache")

local M = {}

--- Resolve a `target` into the list of buffer numbers to collect hunks from.
--- "attached"/nil = every cached buffer, 0 = current buffer, otherwise the given
--- bufnr. Strings (from the :JJSigns CLI) are coerced to numbers, except the
--- literal "attached".
--- @param target "attached"|integer|string|nil
--- @return integer[]
local function resolve_bufs(target)
  if type(target) == "string" and target ~= "attached" then
    target = tonumber(target)
  end

  if target == nil or target == "attached" then
    local bufs = {}
    for bufnr in pairs(cache.all()) do
      bufs[#bufs + 1] = bufnr
    end
    table.sort(bufs)
    return bufs
  end

  if target == 0 then
    return { api.nvim_get_current_buf() }
  end

  return { target }
end

--- One-line description of a hunk for the qf `text` column: the change type plus
--- the diff hunk header (e.g. `change @@ -12,1 +12,1 @@`). Conflicts and pure
--- deletes carry an empty head, so the type alone is shown.
--- @param hunk JJSigns.Hunk
--- @return string
local function hunk_text(hunk)
  local head = hunk.head or ""
  if head == "" then return hunk.type end
  return hunk.type .. " " .. head
end

--- Build quickfix items from cached hunks. Uses entry.hunks directly, so no
--- subprocess runs and unsaved/clean buffers behave the same.
--- @param target "attached"|integer|string|nil  "attached"/nil = all cached
---   buffers, 0 = current buffer, otherwise a specific bufnr
--- @return table[]  quickfix item list ({ bufnr, lnum, text })
function M.build_items(target)
  local items = {}
  for _, bufnr in ipairs(resolve_bufs(target)) do
    local entry = cache.get(bufnr)
    if entry and entry.hunks and api.nvim_buf_is_valid(bufnr) then
      for _, hunk in ipairs(entry.hunks) do
        items[#items + 1] = {
          bufnr = bufnr,
          lnum  = math.max(hunk.added.start, 1),  -- delete/topdelete map to 1
          text  = hunk_text(hunk),
        }
      end
    end
  end
  return items
end

--- Populate the quickfix (or location) list with hunks across buffers.
--- @param target "attached"|integer|string|nil
--- @param opts { open?: boolean, use_loc?: boolean }?  open opens the list;
---   use_loc routes to the current window's location list instead of quickfix
function M.setqflist(target, opts)
  opts = opts or {}
  local items = M.build_items(target)

  if opts.use_loc then
    vim.fn.setloclist(0, items)
    if opts.open then vim.cmd("lopen") end
  else
    vim.fn.setqflist(items)
    if opts.open then vim.cmd("copen") end
  end
end

--- Populate the current window's location list with hunks. Thin wrapper routing
--- setqflist through the loclist path; defaults the target to the current buffer.
--- @param target "attached"|integer|string|nil  defaults to 0 (current buffer)
--- @param opts { open?: boolean }?
function M.setloclist(target, opts)
  opts = opts or {}
  opts.use_loc = true
  if target == nil then target = 0 end
  M.setqflist(target, opts)
end

return M
