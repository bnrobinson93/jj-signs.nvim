#!/usr/bin/env bash
# Create one throwaway jj repo with a small committed Lua program as the base for
# the README demos. The recording driver (make-demo.sh) then makes live edits and
# a rebase conflict on top of it.
#
# Usage: demo-setup.sh <dest-dir>
set -euo pipefail
DEST=${1:?usage: demo-setup.sh <dest-dir>}
mkdir -p "$DEST"

cd "$DEST"
jj git init >/dev/null 2>&1
# Neutral identity so recordings never show the real author name/email.
jj config set --repo user.name  "dev"             >/dev/null 2>&1
jj config set --repo user.email "dev@example.com" >/dev/null 2>&1

cat > hello.lua <<'EOF'
local function greet(name)
  return "Hello, " .. name .. "!"
end

local function main()
  print(greet("world"))
end

main()
EOF

jj describe -m 'add hello.lua' >/dev/null 2>&1
echo "$DEST"
