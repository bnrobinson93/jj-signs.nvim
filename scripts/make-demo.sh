#!/usr/bin/env bash
# Render the README demo GIFs from real nvim+jj sessions recorded with asciinema
# and converted with agg. Only the terminal cell grid is captured — no wallpaper,
# window chrome, hostname, or shell prompt leaks into the pixels, and the
# intermediate .cast files are deleted.
#
#   signs.gif    — `jj new`, then live add/modify/delete a line (signs appear),
#                  undo/redo (signs revert and return), save, then `jj diff`.
#   conflict.gif — `jj new @-` makes a sibling change, edits the same line
#                  differently, rebases onto the first change to force a conflict,
#                  then opens it to show the region tints.
#
# Requires: jj, nvim, asciinema, agg.
set -euo pipefail

PLUGIN=$(cd "$(dirname "$0")/.." && pwd)
OUT="$PLUGIN/assets"
mkdir -p "$OUT"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REPO=$(bash "$PLUGIN/scripts/demo-setup.sh" "$TMP/repo")

WIN="84x26"
# Compact jj log template: graph + short change id + description only. Keeps the
# author name, email, and timestamps (which the default template shows) out of
# the recording.
LOGT='change_id.shortest(4) ++ if(conflict, " conflict", "") ++ "  " ++ if(description, description.first_line(), "(no description)") ++ "\n"'

# ---- shared nvim config ----------------------------------------------------
cat > "$TMP/init.lua" <<EOF
vim.opt.runtimepath:append("$PLUGIN")
vim.o.termguicolors = true
vim.o.background = "dark"
pcall(vim.cmd.colorscheme, "default")
vim.o.number = true
vim.o.signcolumn = "yes"
vim.o.laststatus = 0
vim.o.ruler = false
vim.o.showmode = false
vim.o.cmdheight = 0  -- hide nvim's cmdline (also suppresses the harmless E1568 DSR notice)
vim.o.fillchars = "eob: "
vim.opt.shortmess:append("aoOtTWIcF")
vim.o.autoindent = false
vim.cmd("filetype indent off")  -- keep syntax colors, but no auto-reindent on cc/o
require("jj-signs").setup({
  word_diff = true,
  conflict_hl = true,
  use_decoration_provider = false,  -- place real extmarks so live updates always repaint
  nav = { navigation_message = false },
})
-- Pin sign colors to the documented green/yellow/red, independent of scheme.
local function fg(n, c) vim.api.nvim_set_hl(0, n, { fg = c }) end
fg("JJSignsAdd",          "#a6e3a1")
fg("JJSignsChange",       "#f9e2af")
fg("JJSignsDelete",       "#f38ba8")
fg("JJSignsTopDelete",    "#f38ba8")
fg("JJSignsChangedelete", "#fab387")
-- Demo-only: keep needs_full_diff set so every refresh takes the full-diff path.
-- Otherwise the throttled incremental (dirty-range) refresh queued by on_lines
-- runs after our forced refresh and clears the freshly-placed signs.
local _t = vim.uv.new_timer()
_t:start(0, 40, vim.schedule_wrap(function()
  local e = require("jj-signs.cache").get(0)
  if e then e.needs_full_diff = true end
end))

-- A timed driver (set via \$DEMO_DRIVER) performs the edits, then quits. Wait
-- until jj-signs has attached and seated its base text before starting, so the
-- edits trigger live sign updates regardless of startup timing.
if vim.env.DEMO_DRIVER and vim.env.DEMO_DRIVER ~= "" then
  local function start()
    pcall(function() require("jj-signs").attach(0) end)
    local e = require("jj-signs.cache").get(0)
    if e and e.base_text ~= nil then
      dofile(vim.env.DEMO_DRIVER)
    else
      vim.defer_fn(start, 120)
    end
  end
  vim.defer_fn(start, 200)
end
EOF

# ---- shared driver runtime (human-paced, timed keystrokes) -----------------
# A driver builds a timeline with at()/keys()/type()/edit() (each call advances a
# running clock), then go() schedules them and quit() ends after a final hold.
# Typing goes out one character at a time with slight jitter; cursor moves use
# individual motions so the travel is visible, not an instant jump.
cat > "$TMP/drv.lua" <<'EOF'
math.randomseed(1)
local A = vim.api
local M = { clock = 0 }
local seq = {}
local function force_refresh()
  local e = require("jj-signs.cache").get(0)
  if e then e.needs_full_diff = true end
  pcall(function() require("jj-signs").refresh(0) end)
end
-- schedule fn at clock+delay; advances the clock
function M.at(delay, fn) M.clock = M.clock + delay; seq[#seq + 1] = { M.clock, fn } end
-- nvim_input streams like real typing: it respects the current mode and an insert
-- session coalesces into ONE undo entry, so plain `u`/<C-r> revert whole edits.
function M.key(delay, s) M.at(delay, function() A.nvim_input(s); force_refresh() end) end
-- type literal text one character at a time, with slight jitter (fast, ~28 cps)
function M.type(s, cps)
  local base = math.floor(1000 / (cps or 28))
  for ch in s:gmatch(".") do
    local c = ch == "<" and "<lt>" or ch
    M.at(base + math.random(0, 18), function() A.nvim_input(c); force_refresh() end)
  end
end
function M.go() for _, st in ipairs(seq) do vim.defer_fn(function() pcall(st[2]) end, st[1]) end end
function M.quit_after(extra) vim.defer_fn(function() vim.cmd("qa!") end, M.clock + extra) end
return M
EOF

# driver: live edits + undo/redo on hello.lua (cursor starts at line 1)
cat > "$TMP/driver_signs.lua" <<EOF
local d = dofile("$TMP/drv.lua")
d.key(700, "j")                                     -- travel to line 2
d.key(450, "cc")                                    -- clear it, enter insert
d.type([[  return "Hi there, " .. name .. "!"]])    -- type the new greeting
d.key(220, "<Esc>")                                 -- -> change sign
d.key(700, "j"); d.key(160, "j"); d.key(160, "j"); d.key(160, "j") -- travel to line 6
d.key(450, "o")                                     -- open a line below, insert
d.type([[  print(greet("again"))]])                 -- type the new call
d.key(220, "<Esc>")                                 -- -> add sign
d.key(800, "G")                                     -- travel to the last line
d.key(600, "dd")                                    -- delete it -> delete sign
d.key(1700, "u"); d.key(750, "u"); d.key(750, "u")        -- undo: signs revert
d.key(1200, "<C-r>"); d.key(750, "<C-r>"); d.key(750, "<C-r>") -- redo: signs return
d.key(1000, ":w<CR>")
d.go(); d.quit_after(1500)
EOF

# driver: the sibling change edits the same greeting line differently
cat > "$TMP/driver_alt.lua" <<EOF
local d = dofile("$TMP/drv.lua")
d.key(700, "j")
d.key(450, "cc")
d.type([[  return "Hey, dear " .. name .. "!"]])
d.key(220, "<Esc>")
d.key(700, "G")
d.key(450, "o")
d.type([[  print(greet("again"))]])
d.key(220, "<Esc>")
d.key(1000, ":w<CR>")
d.go(); d.quit_after(1100)
EOF

# driver: hold long enough to read the materialized conflict, then quit
cat > "$TMP/driver_view.lua" <<EOF
local d = dofile("$TMP/drv.lua")
d.go(); d.quit_after(4200)
EOF

# ---- session scripts (what asciinema records) ------------------------------
PROMPT='\033[36m$\033[0m'   # cyan $, no user/host/path
# ps1 drops the prompt the instant the previous command's output ends; say() then
# idles (that pause is the "read the output / think" beat the viewer needs) before
# typing the next command a character at a time. Mirrors a real interactive shell,
# where the prompt is already waiting while you read and start to type.
cat > "$TMP/session_signs.sh" <<EOF
set +e  # linear demo; jj rebase exits 1 on conflict, do not abort
export COLORFGBG="15;0"   # tell nvim the bg is dark so it skips the OSC 11 query
cd "$REPO"
ps1() { printf '%b ' '$PROMPT'; }
say() {  # say <command-text> [think-seconds]
  ps1; sleep "\${2:-0.6}"
  local s=\$1 i
  for ((i = 0; i < \${#s}; i++)); do printf '%s' "\${s:\$i:1}"; sleep 0.08; done
  printf '\n'
}

say "jj new -m 'tweak greeting'" 0.5; jj new -m 'tweak greeting' >/dev/null
say "nvim hello.lua" 0.8;             DEMO_DRIVER="$TMP/driver_signs.lua" nvim -u "$TMP/init.lua" hello.lua
say "jj diff" 0.6;                    jj diff --color=always
ps1; sleep 2.2                        # prompt returns after the diff; linger to read it
EOF

cat > "$TMP/session_conflict.sh" <<EOF
set +e  # linear demo; jj rebase exits 1 on conflict, do not abort
export COLORFGBG="15;0"
cd "$REPO"
ps1() { printf '%b ' '$PROMPT'; }
say() {  # say <command-text> [think-seconds]
  ps1; sleep "\${2:-0.6}"
  local s=\$1 i
  for ((i = 0; i < \${#s}; i++)); do printf '%s' "\${s:\$i:1}"; sleep 0.08; done
  printf '\n'
}

# @ is the tweak change right now; grab its id before branching off.
TWEAK=\$(jj log -r @ --no-graph --color=never -T 'change_id.shortest(8)')
say "jj log" 0.5;                                            jj log --color=always -T '$LOGT'
say "jj new @- -m 'alt greeting'  # sibling of the tweak" 3.2; jj new @- -m 'alt greeting' >/dev/null
say "nvim hello.lua" 0.8;                                    DEMO_DRIVER="$TMP/driver_alt.lua" nvim -u "$TMP/init.lua" hello.lua
say "jj rebase -r @ -d \$TWEAK  # onto the tweak -> conflict" 0.7; jj rebase -r @ -d "\$TWEAK" >/dev/null 2>&1
say "jj log" 0.8;                                            jj log --color=always -T '$LOGT'
say "nvim hello.lua  # conflict materialized" 3.2;          DEMO_DRIVER="$TMP/driver_view.lua" nvim -u "$TMP/init.lua" hello.lua
ps1; sleep 1.0                        # trailing prompt
EOF

# ---- record + render -------------------------------------------------------
record() { asciinema rec --overwrite --quiet --capture-env "" --window-size "$WIN" \
             -c "bash $1" "$2"; }
render() {
  # idle-time-limit 3 keeps deliberate pauses (e.g. lingering on the jj log tree)
  # instead of compressing every gap to 1s; typing pauses are well under it.
  agg --theme nord --font-size 16 \
    --font-family "JetBrainsMono Nerd Font Mono,MesloLGL Nerd Font,DankMono Nerd Font" \
    --idle-time-limit 3 --last-frame-duration 2.5 \
    "$1" "$2"
}

record "$TMP/session_signs.sh"    "$TMP/signs.cast"
render "$TMP/signs.cast"    "$OUT/signs.gif"
echo "wrote $OUT/signs.gif"

record "$TMP/session_conflict.sh" "$TMP/conflict.cast"
render "$TMP/conflict.cast" "$OUT/conflict.gif"
echo "wrote $OUT/conflict.gif"
echo "done"
