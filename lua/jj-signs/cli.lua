--- Command-line interface for jj-signs: the `:JJSigns <action> [args...]` user
--- command and its tab-completion. Thin shim over the public module API in
--- init.lua, mirroring gitsigns' cli.lua so the same actions are reachable from
--- the command line as from Lua.

local unpack = table.unpack or unpack

local M = {}

--- Subcommands callable via `:JJSigns <name> [args...]`. Each name maps to a
--- public function of the same name on the jj-signs module. Kept as an explicit
--- allowlist (rather than blanket-exposing every module field) so only the
--- intentional, argument-safe entry points are reachable from the command line.
local subcommands = {
  "nav_hunk",
  "preview_hunk",
  "preview_hunk_inline",
  "restore_hunk",
  "diffthis",
  "diffthis_rev",
  "change_base",
  "reset_base",
  "blame_line",
  "blame",
  "select_hunk",
  "refresh",
  "refresh_all",
  "attach",
  "detach",
  "detach_all",
  "enable",
  "disable",
  "get_hunks",
  "is_attached",
  "toggle_current_line_blame",
  "toggle_signs",
  "toggle_numhl",
  "toggle_linehl",
  "toggle_word_diff",
  "toggle_deleted",
  "setqflist",
  "setloclist",
}

--- Resolve a subcommand name to its module function.
--- @param name string?
--- @return function?
function M.dispatch(name)
  for _, sub in ipairs(subcommands) do
    if sub == name then
      return require("jj-signs")[sub]
    end
  end
  return nil
end

--- Command-line completion: subcommand names whose prefix matches `arg_lead`.
--- Only the first positional (the action name) is completed.
--- @param arg_lead string
--- @return string[]
function M.complete(arg_lead)
  local matches = {}
  for _, sub in ipairs(subcommands) do
    if vim.startswith(sub, arg_lead) then
      matches[#matches + 1] = sub
    end
  end
  return matches
end

--- Execute a `:JJSigns` invocation. The first positional arg is the action; the
--- remaining args are forwarded positionally to the resolved function (e.g.
--- `:JJSigns nav_hunk next`, `:JJSigns diffthis @--`).
--- @param fargs string[]
function M.run(fargs)
  local name = fargs[1]
  if not name then
    vim.notify("jj-signs: usage: :JJSigns <action> [args...]", vim.log.levels.WARN)
    return
  end

  local fn = M.dispatch(name)
  if not fn then
    vim.notify("jj-signs: unknown action '" .. name .. "'", vim.log.levels.WARN)
    return
  end

  fn(unpack(fargs, 2))
end

--- Register the `:JJSigns` user command. Idempotent — safe to call from both
--- plugin/jj-signs.lua (so the command exists before setup) and setup().
--- The callback lazily initializes jj-signs with defaults if setup() has not
--- run yet, so the command works out of the box.
function M.create_command()
  vim.api.nvim_create_user_command("JJSigns", function(opts)
    local jjsigns = require("jj-signs")
    if not jjsigns._initialized then
      jjsigns.setup({})
    end
    M.run(opts.fargs)
  end, {
    nargs = "*",
    complete = function(arg_lead)
      return M.complete(arg_lead)
    end,
    desc = "Run a jj-signs action (see :JJSigns <Tab>)",
  })
end

return M
