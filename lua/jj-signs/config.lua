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
--- @field on_attach?      fun(bufnr: integer): boolean?

M.defaults = {
  -- Sign characters match LazyVim's gitsigns config; highlights link to standard
  -- diff groups so any colorscheme works without configuration.
  signs = {
    add      = { text = "▎", hl = "JJSignsAdd" },
    change   = { text = "▎", hl = "JJSignsChange" },
    delete   = { text = "▁", hl = "JJSignsDelete" },
    conflict = { text = "╪", hl = "JJSignsConflict" },
  },
  signcolumn      = true,
  numhl           = false,
  linehl          = false,
  update_debounce = 100,   -- matches gitsigns default
  max_file_length = 40000, -- matches gitsigns default
  sign_priority   = 6,
  jj_cmd          = "jj",
  -- Optional: passed as `jj --repository <path>`. Leave nil to rely on cwd-based
  -- workspace detection, which handles all standard JJ workspace setups.
  jj_repo         = nil,
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
