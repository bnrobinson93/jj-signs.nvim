local api = vim.api
local M = {}

local word_ns = api.nvim_create_namespace("jj-signs-word")

-- Split string into one-byte-per-line for vim.diff indices mode.
-- vim.diff result_type="indices" returns line numbers; one byte per line
-- maps line numbers directly to byte column positions.
local function to_lines(s)
  local t = {}
  for i = 1, #s do t[i] = s:sub(i, i) end
  return #t > 0 and (table.concat(t, "\n") .. "\n") or ""
end

local function run_word_diff(removed_lines, added_lines)
  local removed_regions = {}
  local added_regions   = {}
  local line_count = math.min(#removed_lines, #added_lines)
  for i = 1, line_count do
    local rline = removed_lines[i]
    local aline = added_lines[i]
    local rdiffs = vim.diff(to_lines(rline), to_lines(aline), require("jj-signs.diff").build_diff_opts({ result_type = "indices" }))
    if rdiffs then
      for _, r in ipairs(rdiffs) do
        local rs, rc, as, ac = r[1], r[2], r[3], r[4]
        if rc > 0 then
          removed_regions[#removed_regions+1] = { lnum = i, start_col = rs - 1, end_col = rs - 1 + rc }
        end
        if ac > 0 then
          added_regions[#added_regions+1] = { lnum = i, start_col = as - 1, end_col = as - 1 + ac }
        end
      end
    end
  end
  return removed_regions, added_regions
end

M._run_word_diff = run_word_diff

-- Memoize computed word-diff regions per buffer, keyed by change_id and by hunk
-- content. place_word_diff runs on every signs.place (re-render, toggle, narrow
-- refresh); without this every change hunk re-ran vim.diff each time. Keying on
-- the hunk's removed+added text makes the memo self-invalidating, and resetting
-- it when change_id flips bounds growth across revisions.
local memo = {} --- @type table<integer, { change_id: string?, regions: table<string, table[]> }>
M._memo = memo

local function hunk_key(hunk)
  return table.concat(hunk.removed.lines, "\n") .. "\0" .. table.concat(hunk.added.lines, "\n")
end

--- @param bufnr integer
--- @param hunks JJSigns.Hunk[]
--- @param change_id string?  current @ change_id; flips the memo when it changes
function M.place_word_diff(bufnr, hunks, change_id)
  api.nvim_buf_clear_namespace(bufnr, word_ns, 0, -1)
  local config = require("jj-signs.config")

  local m = memo[bufnr]
  local prev = (m and m.change_id == change_id) and m.regions or {}
  -- Rebuild the region map from the current hunk set, reusing prior results for
  -- unchanged hunks. Building fresh (rather than mutating prev) drops keys for
  -- hunks that no longer exist, so the memo can't grow unbounded mid-revision.
  local cur = {}

  for _, hunk in ipairs(hunks) do
    if hunk.type == "change" and #hunk.removed.lines > 0 and #hunk.added.lines > 0 then
      local key = hunk_key(hunk)
      local added_regions = prev[key]
      if not added_regions then
        local _, ar = run_word_diff(hunk.removed.lines, hunk.added.lines)
        added_regions = ar
      end
      cur[key] = added_regions
      for _, region in ipairs(added_regions) do
        local lnum = hunk.added.start + region.lnum - 1
        pcall(api.nvim_buf_set_extmark, bufnr, word_ns, lnum - 1, region.start_col, {
          end_col  = region.end_col,
          hl_group = "JJSignsChangeWord",
          priority = config.config.sign_priority + 1,
        })
      end
    end
  end

  memo[bufnr] = { change_id = change_id, regions = cur }
end

function M.clear_word_diff(bufnr)
  api.nvim_buf_clear_namespace(bufnr, word_ns, 0, -1)
  memo[bufnr] = nil
end

return M
