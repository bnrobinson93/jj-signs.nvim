local M = {}

--- @class JJSigns.Config
--- @field signs           table<JJSigns.HunkType, { text: string, hl: string }>
--- @field signcolumn      boolean
--- @field numhl           boolean
--- @field linehl          boolean
--- @field update_debounce integer
--- @field max_file_length integer
--- @field sign_priority   integer
--- @field jj_cmd          string
--- @field jj_repo         string?
--- @field status_formatter fun(dict: table): string
--- @field on_attach?      fun(bufnr: integer): boolean?

M.defaults = {
  -- Sign characters match LazyVim's gitsigns config; highlights link to standard
  -- diff groups so any colorscheme works without configuration.
  signs = {
    add          = { text = "▎", hl = "JJSignsAdd" },
    change       = { text = "▎", hl = "JJSignsChange" },
    delete       = { text = "▁", hl = "JJSignsDelete" },
    topdelete    = { text = "▔", hl = "JJSignsTopDelete" },
    changedelete = { text = "▎", hl = "JJSignsChangedelete" },
    conflict     = { text = "╪", hl = "JJSignsConflict" },
  },
  signcolumn      = true,
  numhl           = false,
  linehl          = false,
  update_debounce = 100,   -- matches gitsigns default
  max_file_length = 40000, -- matches gitsigns default
  sign_priority   = 6,
  jj_cmd          = "jj",
  current_line_blame = false,
  current_line_blame_opts = {
    virt_text     = true,
    virt_text_pos = "eol",
    delay         = 1000,
    format        = "‹ %s • %a • %r",
  },
  word_diff      = false,
  show_deleted   = false,
  -- Optional: passed as `jj --repository <path>`. Leave nil to rely on cwd-based
  -- workspace detection, which handles all standard JJ workspace setups.
  jj_repo         = nil,
  -- Builds the b:jjsigns_status string from b:jjsigns_status_dict. Default emits
  -- "+N ~N -N", omitting any zero part. Override to customize statusline output.
  status_formatter = function(d)
    local parts = {}
    if (d.added   or 0) > 0 then parts[#parts + 1] = "+" .. d.added   end
    if (d.changed or 0) > 0 then parts[#parts + 1] = "~" .. d.changed end
    if (d.removed or 0) > 0 then parts[#parts + 1] = "-" .. d.removed end
    return table.concat(parts, " ")
  end,
  use_decoration_provider = true,
  -- Callback invoked after attaching to a buffer. Set up buffer-local keymaps here.
  -- Return false to cancel the attach. When nil, built-in default keymaps are used.
  on_attach       = nil,
} --[[@as JJSigns.Config]]

--- @type JJSigns.Config
M.config = {}

--- @param opts table?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
