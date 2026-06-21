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
--- @field preview_config  JJSigns.PreviewConfig
--- @field nav             JJSigns.NavConfig

--- @class JJSigns.PreviewConfig
--- @field border   string|string[]  float border style (any nvim_open_win border value)
--- @field style    string           float window style (e.g. "minimal")
--- @field relative string           float positioning base (e.g. "cursor")
--- @field row      integer
--- @field col      integer

--- @class JJSigns.NavConfig
--- @field wrap               boolean  wrap around buffer ends (default true)
--- @field navigation_message boolean  echo "Hunk N of M" after a jump (default true)
--- @field foldopen           boolean  open folds at the destination (default true)
--- @field preview            boolean|"inline"  auto-open a preview after a jump (default false)

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
  -- Floating preview_hunk() window appearance. `preview_hunk_inline()` ignores
  -- this (it renders virtual lines in-buffer, no float).
  preview_config = {
    border   = "rounded",
    style    = "minimal",
    relative = "cursor",
    row      = 1,
    col      = 0,
  },
  -- nav_hunk() defaults. Each is overridable per call via the opts argument.
  nav = {
    wrap               = true,  -- wrap around buffer ends
    navigation_message = true,  -- echo "Hunk N of M" after a jump
    foldopen           = true,  -- open folds at the destination
    preview            = false, -- true = float, "inline" = virtual lines
  },
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
