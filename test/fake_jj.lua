--- Scriptable fake for the jj subprocess adapter (jj.lua).
---
--- The adapter is the single seam between jj-signs and the `jj` CLI, so faking it
--- lets a test drive a whole vertical — refresh, blame, diffthis, change_base —
--- through the REAL pipeline with scripted jj I/O, no per-test `vim.system` stubs.
---
--- Consumers captured `local jj = require("jj-signs.jj")` at load time, so we
--- monkeypatch the real module table's functions (mutating fields the captured
--- reference already points at) rather than swapping `package.loaded`.
---
--- Callbacks fire synchronously. Production fires them on a later tick via
--- `vim.schedule`; the pipeline's `await` is written to handle a synchronous
--- callback (see its doc-comment), and the blame/diffthis callbacks are plain, so
--- immediate invocation is safe and keeps tests deterministic.

local jj = require("jj-signs.jj")

local M = {}

--- Install the fake. `opts` fields (all optional):
---   root        string|false  get_root result; false = "not a jj repo" (nil);
---                             unset defaults to "/fake/root".
---   change_id   string        default "cid"
---   bookmark    string        default ""
---   description string        default ""
---   parents     { pcid, ppid } default { "pcid", "ppid" }
---   base        string        fetch_base result; default "" (new file)
---   annotate    string|false  annotate stdout; false = failure (nil); default ""
---   show        string|false  show stdout;     false = failure (nil); default ""
---   file_show   string|false  file_show stdout; false = failure (nil); default ""
--- `M.calls` counts invocations per function after install.
--- @param opts table?
function M.install(opts)
  opts = opts or {}

  M._orig = {
    get_root       = jj.get_root,
    get_change_id  = jj.get_change_id,
    get_parent_ids = jj.get_parent_ids,
    fetch_base     = jj.fetch_base,
    file_show      = jj.file_show,
    annotate       = jj.annotate,
    show           = jj.show,
  }

  M.calls = {
    get_root = 0, get_change_id = 0, get_parent_ids = 0,
    fetch_base = 0, file_show = 0, annotate = 0, show = 0,
  }

  -- false/nil = not a repo → cb(nil); unset (opts.root == nil) → default root.
  jj.get_root = function(_, cb)
    M.calls.get_root = M.calls.get_root + 1
    if opts.root == nil then cb("/fake/root") else cb(opts.root or nil) end
  end

  jj.get_change_id = function(_, cb)
    M.calls.get_change_id = M.calls.get_change_id + 1
    cb(opts.change_id or "cid", opts.bookmark or "", opts.description or "")
  end

  jj.get_parent_ids = function(_, _, cb)
    M.calls.get_parent_ids = M.calls.get_parent_ids + 1
    local p = opts.parents or { "pcid", "ppid" }
    cb(p[1], p[2])
  end

  jj.fetch_base = function(_, _, _, cb)
    M.calls.fetch_base = M.calls.fetch_base + 1
    cb(opts.base or "")
  end

  -- annotate/show/file_show: unset → "", explicit false → nil (failure).
  local function stdout_of(v) return v == nil and "" or (v or nil) end

  jj.file_show = function(_, _, _, cb)
    M.calls.file_show = M.calls.file_show + 1
    cb(stdout_of(opts.file_show))
  end

  jj.annotate = function(_, _, cb)
    M.calls.annotate = M.calls.annotate + 1
    cb(stdout_of(opts.annotate))
  end

  jj.show = function(_, _, cb)
    M.calls.show = M.calls.show + 1
    cb(stdout_of(opts.show))
  end
end

--- Restore the real adapter functions. Safe to call when not installed.
function M.restore()
  if not M._orig then return end
  for k, v in pairs(M._orig) do jj[k] = v end
  M._orig = nil
end

return M
