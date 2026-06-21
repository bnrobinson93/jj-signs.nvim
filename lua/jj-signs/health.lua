--- `:checkhealth jj-signs` diagnostics. Neovim resolves this module via
--- `lua/jj-signs/health.lua` and calls `M.check()`. Uses the modern
--- `vim.health` API (start/ok/warn/error/info), not the deprecated
--- `health.report_*` shims.

local M = {}

-- Oldest jj release this plugin is known to work against. `jj annotate` (used
-- by blame) and the `jj diff --from/--to` flags (used by change_base) are the
-- gating features; both are stable as of this release. Older jj may still work
-- for plain signs but is untested.
local MIN_JJ_VERSION = { 0, 18, 0 }

--- Parse "jj 0.42.0\n…" into { major, minor, patch }. Returns nil if no
--- dotted version triple is present in the output.
--- @param out string?
--- @return integer[]?
local function parse_jj_version(out)
  if not out then return nil end
  local major, minor, patch = out:match("(%d+)%.(%d+)%.(%d+)")
  if not major then return nil end
  return { tonumber(major), tonumber(minor), tonumber(patch) }
end

--- @param a integer[]
--- @param b integer[]
--- @return boolean  true when a < b
local function version_lt(a, b)
  for i = 1, 3 do
    local x, y = a[i] or 0, b[i] or 0
    if x ~= y then return x < y end
  end
  return false
end

local function ver_str(v)
  return table.concat(v, ".")
end

function M.check()
  local health = vim.health
  health.start("jj-signs")

  -- config.config is populated by setup(); fall back to defaults so health
  -- works even when invoked before setup() has run.
  local config = require("jj-signs.config")
  local cfg = config.config
  local jj_cmd = (cfg and cfg.jj_cmd) or config.defaults.jj_cmd

  -- Neovim version
  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()) .. " (>= 0.10)")
  else
    health.error("Neovim >= 0.10 required", "Upgrade Neovim")
  end

  -- jj executable
  if vim.fn.executable(jj_cmd) == 0 then
    health.error(
      "'" .. jj_cmd .. "' not found in PATH",
      { "Install jj: https://github.com/jj-vcs/jj", "Or set jj_cmd to the absolute path in setup()" }
    )
    -- Without jj there is nothing more to verify.
    M._report_runtime()
    return
  end
  health.ok("'" .. jj_cmd .. "' found in PATH")

  -- jj version
  local res = vim.system({ jj_cmd, "--version" }):wait()
  if res.code ~= 0 then
    health.warn("'" .. jj_cmd .. " --version' failed (exit " .. res.code .. ")")
  else
    local ver = parse_jj_version(res.stdout)
    if not ver then
      health.warn("Could not parse jj version from: " .. vim.trim(res.stdout or ""))
    elseif version_lt(ver, MIN_JJ_VERSION) then
      health.warn(
        "jj " .. ver_str(ver) .. " is older than known-good " .. ver_str(MIN_JJ_VERSION),
        "Blame (jj annotate) and change_base may not work; upgrade jj"
      )
    else
      health.ok("jj " .. ver_str(ver) .. " (>= " .. ver_str(MIN_JJ_VERSION) .. ")")
    end
  end

  -- jj_repo misconfig (P10b)
  local jj_repo = cfg and cfg.jj_repo
  if jj_repo ~= nil then
    if type(jj_repo) ~= "string" or jj_repo == "" then
      health.error("jj_repo is set but not a non-empty string")
    elseif vim.fn.isdirectory(jj_repo) == 0 then
      health.error("jj_repo points at a non-directory: " .. jj_repo)
    else
      local root = vim.system({ jj_cmd, "--repository", jj_repo, "root" }):wait()
      if root.code ~= 0 then
        health.error(
          "jj_repo is not a valid jj workspace: " .. jj_repo,
          "Run `jj root` there, or unset jj_repo to use cwd-based detection"
        )
      else
        health.ok("jj_repo valid: " .. vim.trim(root.stdout or ""))
      end
    end
  else
    health.info("jj_repo unset — using cwd-based workspace detection")
  end

  -- Decoration provider (P10b)
  local use_provider = not cfg or cfg.use_decoration_provider == nil
    or cfg.use_decoration_provider
  if use_provider then
    health.ok("use_decoration_provider enabled (signs rendered for visible lines)")
  else
    health.info("use_decoration_provider disabled — signs placed eagerly via extmarks")
  end

  M._report_runtime()
end

--- Report attached buffers and active watchers. Split out so the early-return
--- path (no jj) still emits it.
function M._report_runtime()
  local health = vim.health

  local cache = require("jj-signs.cache")
  local n_attached = 0
  for _ in pairs(cache.all()) do
    n_attached = n_attached + 1
  end
  health.info(n_attached .. " attached buffer" .. (n_attached == 1 and "" or "s"))

  local watcher = require("jj-signs.watcher")
  local n_watchers = 0
  for _ in pairs(watcher._watchers) do
    n_watchers = n_watchers + 1
  end
  health.info(n_watchers .. " active op-log watcher" .. (n_watchers == 1 and "" or "s"))

  local jjsigns = package.loaded["jj-signs"]
  if jjsigns and jjsigns._enabled == false then
    health.warn("jj-signs is globally disabled (call require('jj-signs').enable())")
  end
end

return M
