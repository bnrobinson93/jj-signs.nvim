--- Health-check tests. vim.health and the jj-dependent vim.fn calls are mocked
--- so the unit path never shells out to a real jj. Each test stubs the
--- environment, runs M.check(), and inspects the captured health calls.

local h = require("test.helpers")
local eq = h.eq

local health = require("jj-signs.health")
local config = require("jj-signs.config")
local cache  = require("jj-signs.cache")

-- Collect emitted health calls as { level = "ok"|"warn"|"error"|"info", msg }.
local function install_health_capture()
  local calls = {}
  local function rec(level)
    return function(msg) calls[#calls + 1] = { level = level, msg = msg } end
  end
  vim.health = {
    start = function() end,
    ok    = rec("ok"),
    warn  = rec("warn"),
    error = rec("error"),
    info  = rec("info"),
  }
  return calls
end

-- Count calls of a given level.
local function count(calls, level)
  local n = 0
  for _, c in ipairs(calls) do
    if c.level == level then n = n + 1 end
  end
  return n
end

-- True if any call of `level` contains `substr`.
local function has(calls, level, substr)
  for _, c in ipairs(calls) do
    if c.level == level and tostring(c.msg):find(substr, 1, true) then
      return true
    end
  end
  return false
end

-- Stub vim.system to return a fixed { code, stdout } from :wait().
local function stub_system(code, stdout)
  vim.system = function()
    return { wait = function() return { code = code, stdout = stdout } end }
  end
end

describe("health.check", function()
  local saved

  before_each(function()
    saved = {
      health      = vim.health,
      executable  = vim.fn.executable,
      system      = vim.system,
      isdirectory = vim.fn.isdirectory,
      has         = vim.fn.has,
    }
    -- Clear any attached buffers from other specs.
    for buf in pairs(cache.all()) do cache.clear(buf) end
    config.setup({})
  end)

  after_each(function()
    vim.health        = saved.health
    vim.fn.executable = saved.executable
    vim.system        = saved.system
    vim.fn.isdirectory = saved.isdirectory
    vim.fn.has        = saved.has
  end)

  it("errors when jj is not executable", function()
    local calls = install_health_capture()
    vim.fn.executable = function() return 0 end
    vim.fn.has = function() return 1 end

    health.check()

    assert.is_true(has(calls, "error", "not found in PATH"))
    -- Runtime report still emitted on the early-return path.
    assert.is_true(has(calls, "info", "attached buffer"))
  end)

  it("ok for a current jj version", function()
    local calls = install_health_capture()
    vim.fn.executable = function() return 1 end
    vim.fn.has = function() return 1 end
    stub_system(0, "jj 0.42.0\n")

    health.check()

    assert.is_true(has(calls, "ok", "found in PATH"))
    assert.is_true(has(calls, "ok", "jj 0.42.0"))
    assert.is_true(count(calls, "error") == 0)
  end)

  it("warns for an old jj version", function()
    local calls = install_health_capture()
    vim.fn.executable = function() return 1 end
    vim.fn.has = function() return 1 end
    stub_system(0, "jj 0.10.0\n")

    health.check()

    assert.is_true(has(calls, "warn", "older than known-good"))
  end)

  it("errors for an invalid jj_repo", function()
    local calls = install_health_capture()
    vim.fn.executable = function() return 1 end
    vim.fn.has = function() return 1 end
    stub_system(0, "jj 0.42.0\n")
    vim.fn.isdirectory = function() return 0 end
    config.config.jj_repo = "/no/such/dir"

    health.check()

    assert.is_true(has(calls, "error", "non-directory"))
  end)

  it("reports attached buffer count", function()
    local calls = install_health_capture()
    vim.fn.executable = function() return 1 end
    vim.fn.has = function() return 1 end
    stub_system(0, "jj 0.42.0\n")

    cache.set(1, { root = "/x", change_id = "", mtime = 0, hunks = {}, dirty = true })
    cache.set(2, { root = "/x", change_id = "", mtime = 0, hunks = {}, dirty = true })

    health.check()

    assert.is_true(has(calls, "info", "2 attached buffers"))
    cache.clear(1)
    cache.clear(2)
  end)
end)
