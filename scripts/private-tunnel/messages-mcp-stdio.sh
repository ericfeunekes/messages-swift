#!/bin/zsh
set -euo pipefail
unset CONTROL_PLANE_API_KEY OPENAI_API_KEY
bridge="$HOME/Applications/Messages Swift.app/Contents/MacOS/messages-mcp"
[[ -x "$bridge" ]] || { print -u2 "Messages Swift bridge is missing or not executable."; exit 66; }
exec "$bridge"
