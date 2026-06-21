--- Runtime toggle tests: each toggle_* flips its config flag, re-places signs
--- for attached buffers, returns the new boolean, and honors an explicit value.

local jjsigns = require("jj-signs")
local cache   = require("jj-signs.cache")
local config  = require("jj-signs.config")
local signs   = require("jj-signs.signs")
local h       = require("test.helpers")
local eq      = h.eq

-- (toggle fn name, config flag) pairs. Default flag values come from config.defaults.
local cases = {
  { "toggle_signs",     "signcolumn"   },
  { "toggle_numhl",     "numhl"        },
  { "toggle_linehl",    "linehl"       },
  { "toggle_word_diff", "word_diff"    },
  { "toggle_deleted",   "show_deleted" },
}

describe("toggles", function()
  local bufnr
  local place_calls
  local orig_place

  before_each(function()
    config.setup({})
    bufnr = vim.api.nvim_create_buf(false, true)
    cache.set(bufnr, {
      root      = "/tmp/x",
      change_id = "",
      mtime     = 0,
      hunks     = {},
      dirty     = false,
    })
    place_calls = 0
    orig_place  = signs.place
    signs.place = function() place_calls = place_calls + 1 end
  end)

  after_each(function()
    signs.place = orig_place
    cache.clear(bufnr)
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  for _, c in ipairs(cases) do
    local fn_name, flag = c[1], c[2]

    describe(fn_name, function()
      it("flips the flag and returns the new value", function()
        local before = config.config[flag]
        local ret = jjsigns[fn_name]()
        eq(not before, config.config[flag])
        eq(not before, ret)
      end)

      it("re-places signs for attached buffers", function()
        jjsigns[fn_name]()
        assert.is_true(place_calls >= 1)
      end)

      it("accepts an explicit value", function()
        local ret = jjsigns[fn_name](true)
        eq(true, config.config[flag])
        eq(true, ret)

        ret = jjsigns[fn_name](false)
        eq(false, config.config[flag])
        eq(false, ret)
      end)
    end)
  end

  it("_reapply_all skips invalid buffers", function()
    local dead = vim.api.nvim_create_buf(false, true)
    cache.set(dead, { root = "/tmp/x", change_id = "", mtime = 0, hunks = {}, dirty = false })
    vim.api.nvim_buf_delete(dead, { force = true })

    assert.has_no.errors(function() jjsigns._reapply_all() end)
    cache.clear(dead)
  end)
end)

describe("toggles are reachable via :JJSigns", function()
  local cli = require("jj-signs.cli")

  for _, c in ipairs(cases) do
    local fn_name = c[1]
    it("dispatches " .. fn_name, function()
      eq("function", type(cli.dispatch(fn_name)))
    end)
  end
end)
