local M = {}
local unpack = table.unpack or _G.unpack  -- LuaJIT exposes the global form

--- Wrap an async-callback function so it can be called like a regular
--- function from a coroutine.
--- @param fn function  async fn whose LAST argument is a callback(result)
--- @param argc integer number of non-callback args
--- @return function
function M.wrap(fn, argc)
  return function(...)
    local args = {...}
    local co = coroutine.running()
    args[argc + 1] = function(result)
      if coroutine.status(co) == "suspended" then
        vim.schedule(function() coroutine.resume(co, result) end)
      end
    end
    fn(unpack(args, 1, argc + 1))
    return coroutine.yield()
  end
end

--- Run fn in a coroutine.
--- @param fn function
function M.run(fn, ...)
  local co = coroutine.create(fn)
  local ok, err = coroutine.resume(co, ...)
  if not ok then
    vim.schedule(function() error(tostring(err), 0) end)
  end
end

--- Schedule a function on the next main-loop tick.
--- @param fn function
function M.schedule(fn)
  vim.schedule(fn)
end

--- Per-buffer throttle: if a call arrives while one is running for the same
--- key, mark pending; re-invoke once the current run finishes.
--- @param fn       fun(bufnr: integer)  async function (will be called in its own coroutine)
--- @param key_fn   fun(...): any        extracts the throttle key from fn's args (usually bufnr)
--- @return fun(...)
function M.throttle_async(fn, key_fn)
  local running = {} --- @type table<any, true>
  local pending  = {} --- @type table<any, true>

  local function invoke(key, ...)
    local args = {...}
    running[key] = true
    M.run(function()
      local ok, err = pcall(fn, unpack(args))
      if not ok then
        vim.schedule(function() vim.notify("[jj-signs] " .. tostring(err), vim.log.levels.WARN) end)
      end
      running[key] = nil
      if pending[key] then
        pending[key] = nil
        invoke(key, unpack(args))
      end
    end)
  end

  return function(...)
    local key = key_fn(...)
    if running[key] then
      pending[key] = true
    else
      invoke(key, ...)
    end
  end
end

return M
