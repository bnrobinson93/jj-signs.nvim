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
#   features.gif — builds two ancestor changes, then tours the interactive
#                  features on a wip change: word-diff, nav_hunk, inline hunk
#                  preview, change_base @-- (widen the comparison), blame_line
#                  popup, and the full-file blame split.
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
vim.o.cmdheight = 1  -- keep the command line visible so typed :JJSigns commands show
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

-- Demo keycast: mirror keystrokes in a small pill at the bottom-right so viewers
-- can follow the hotkeys/motions. Ex commands (mode "c") are skipped — the visible
-- command line already shows those, and the lone ":" that opens it is dropped too.
vim.api.nvim_set_hl(0, "DemoKeycast", { fg = "#1e1e2e", bg = "#f9e2af", bold = true })
local kc = { buf = vim.api.nvim_create_buf(false, true), win = nil, text = "", timer = vim.uv.new_timer() }
local function kc_render()
  if kc.text == "" then
    if kc.win and vim.api.nvim_win_is_valid(kc.win) then vim.api.nvim_win_close(kc.win, true) end
    kc.win = nil
    return
  end
  local label = " " .. kc.text .. " "
  vim.api.nvim_buf_set_lines(kc.buf, 0, -1, false, { label })
  vim.api.nvim_buf_add_highlight(kc.buf, -1, "DemoKeycast", 0, 0, -1)
  local cfg = {
    relative = "editor", anchor = "SE",
    row = vim.o.lines - 1 - vim.o.cmdheight, col = vim.o.columns,
    width = vim.fn.strdisplaywidth(label), height = 1,
    style = "minimal", focusable = false, zindex = 250, noautocmd = true,
  }
  if kc.win and vim.api.nvim_win_is_valid(kc.win) then
    vim.api.nvim_win_set_config(kc.win, cfg)
  else
    kc.win = vim.api.nvim_open_win(kc.buf, false, cfg)
    vim.wo[kc.win].winhl = "Normal:DemoKeycast"
  end
end
vim.on_key(function(_, typed)
  if not typed or typed == "" then return end
  if vim.fn.mode() == "c" then return end
  local pretty = vim.fn.keytrans(typed):gsub("<Space>", "␣")
  if pretty == "" or pretty == ":" then return end
  vim.schedule(function()
    kc.text = (kc.text .. pretty):sub(-22)
    kc_render()
    kc.timer:stop()
    kc.timer:start(1100, 0, vim.schedule_wrap(function() kc.text = ""; kc_render() end))
  end)
end)

-- The headless pty never answers nvim's background-color DSR, so nvim prints a
-- one-time E1568 warning on the command line at startup. Wipe the message area
-- for the first ~1s; the tour's typed commands come seconds later, untouched.
local _clr, _n = vim.uv.new_timer(), 0
_clr:start(40, 40, vim.schedule_wrap(function()
  _n = _n + 1
  vim.api.nvim_echo({ { "" } }, false, {})
  if _n > 25 then _clr:stop(); _clr:close() end
end))

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
-- type an Ex command visibly: `before` waits (so the previous action's result
-- stays on screen), then the cmdline opens and the command is spelled out, then
-- `hold` lets the finished command be read before <CR> runs it.
function M.cmd(text, before, hold)
  M.key(before or 700, ":")
  M.type(text)
  M.key(hold or 800, "<CR>")
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

# driver: guided tour of the interactive features on a wip change with real
# history behind it — word-diff, nav_hunk, inline preview, change_base, blame.
cat > "$TMP/driver_features.lua" <<EOF
local d = dofile("$TMP/drv.lua")

-- 1) live-edit the greeting -> change sign + intra-line word-diff highlight
d.key(700, "j")                                       -- travel to the greet line
d.key(450, "cc")
d.type([[  return "Howdy there, " .. name .. "!"]])   -- only a couple words differ
d.key(220, "<Esc>")

-- 2) add a call below farewell -> a second hunk to navigate between
d.key(1500, ":11<CR>")
d.key(450, "o")
d.type([[  print("done")]])
d.key(220, "<Esc>")

-- 3) nav_hunk: jump first -> next between the two hunks
d.cmd("JJSigns nav_hunk first")
d.cmd("JJSigns nav_hunk next", 1000)

-- 4) preview_hunk_inline: removed line dimmed above, cleared on the next move
d.cmd("JJSigns nav_hunk first", 1000)
d.cmd("JJSigns preview_hunk_inline")
d.key(1900, "l")

-- 5) change_base @--: widen the comparison one change further back (more signs),
--    then reset_base back to the default @-
d.cmd("JJSigns change_base @--", 1000)
d.cmd("JJSigns reset_base", 2200)

-- 6) blame_line: popup the cursor line's change description, move to dismiss
d.cmd("JJSigns nav_hunk first", 1200)
d.cmd("JJSigns blame_line")
d.key(2000, "j")

-- 7) blame: full-file blame split (change_id • author • date), q to close
d.cmd("JJSigns blame", 1000)
d.key(2600, "q")

d.go(); d.quit_after(1400)
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

cat > "$TMP/session_features.sh" <<EOF
set +e
export COLORFGBG="15;0"
cd "$REPO"
ps1() { printf '%b ' '$PROMPT'; }
say() {  # say <command-text> [think-seconds]
  ps1; sleep "\${2:-0.6}"
  local s=\$1 i
  for ((i = 0; i < \${#s}; i++)); do printf '%s' "\${s:\$i:1}"; sleep 0.08; done
  printf '\n'
}

# Build two ancestor changes off-camera so the tour has real history to blame and
# to widen against (change_base @-- reaches past the farewell change). Silence
# jj's "Working copy now at" chatter so it never lands in the opening frame.
jj new -m 'greeting v2' >/dev/null 2>&1
cat > hello.lua <<'LUA'
local function greet(name)
  return "Hey there, " .. name .. "!"
end

local function main()
  print(greet("world"))
end

main()
LUA

jj new -m 'add farewell' >/dev/null 2>&1
cat > hello.lua <<'LUA'
local function greet(name)
  return "Hey there, " .. name .. "!"
end

local function farewell(name)
  return "Bye, " .. name .. "!"
end

local function main()
  print(greet("world"))
  print(farewell("world"))
end

main()
LUA

say "jj new -m wip" 0.5;   jj new -m 'wip' >/dev/null
# --cmd 'set background=dark' decides the background before the TUI attaches, so
# nvim skips the OSC/DSR bg query that agg's headless pty never answers (E1568).
say "nvim hello.lua" 0.8;  DEMO_DRIVER="$TMP/driver_features.lua" nvim --cmd 'set background=dark' -u "$TMP/init.lua" hello.lua
ps1; sleep 1.2
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

# ONLY=<name>[,<name>] limits which gifs are (re)built; default builds all three.
want() { [ -z "${ONLY:-}" ] || case ",$ONLY," in *",$1,"*) return 0;; *) return 1;; esac; }

if want signs; then
record "$TMP/session_signs.sh"    "$TMP/signs.cast"
render "$TMP/signs.cast"    "$OUT/signs.gif"
echo "wrote $OUT/signs.gif"
fi

if want conflict; then
record "$TMP/session_conflict.sh" "$TMP/conflict.cast"
render "$TMP/conflict.cast" "$OUT/conflict.gif"
echo "wrote $OUT/conflict.gif"
fi

if want features; then
record "$TMP/session_features.sh" "$TMP/features.cast"
render "$TMP/features.cast" "$OUT/features.gif"
echo "wrote $OUT/features.gif"
fi
echo "done"
