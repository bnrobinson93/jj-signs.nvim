local api = vim.api
local M = {}

local word_ns = api.nvim_create_namespace("jj-signs-word")

local function run_word_diff(removed_lines, added_lines)
  local removed_regions = {}
  local added_regions   = {}
  local line_count = math.min(#removed_lines, #added_lines)
  for i = 1, line_count do
    local rline = removed_lines[i]
    local aline = added_lines[i]
    local rdiffs = vim.diff(rline .. "\n", aline .. "\n", { result_type = "indices" })
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

function M.place_word_diff(bufnr, hunks)
  api.nvim_buf_clear_namespace(bufnr, word_ns, 0, -1)
  local config = require("jj-signs.config")
  for _, hunk in ipairs(hunks) do
    if hunk.type == "change" and #hunk.removed.lines > 0 and #hunk.added.lines > 0 then
      local _, added_regions = run_word_diff(hunk.removed.lines, hunk.added.lines)
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
end

function M.clear_word_diff(bufnr)
  api.nvim_buf_clear_namespace(bufnr, word_ns, 0, -1)
end

return M
