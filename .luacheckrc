-- Luacheck config for jj-signs.nvim.
-- `vim` is the editor global. Use the permissive `max` std so both `table.unpack`
-- (Lua 5.2+) and the LuaJIT global `unpack` fallback are recognized.
std = "max"
read_globals = { "vim" }

-- LuaCATS @param/@field annotations and a few inline strings run past 120;
-- allow a little more headroom rather than wrapping type annotations.
max_line_length = 140

-- Test files use busted/plenary-style globals.
files["test/"] = {
  globals = { "describe", "it", "before_each", "after_each", "pending" },
  read_globals = { "assert" },
}
