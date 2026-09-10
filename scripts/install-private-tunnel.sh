#!/bin/zsh
set -euo pipefail
umask 077
[[ $# -eq 4 && "$1" == "--tunnel-id" && "$3" == "--tunnel-client" ]] || { print -u2 "usage: $0 --tunnel-id ID --tunnel-client PATH"; exit 64; }
tunnel_id="$2"; client="$4"; tunnel_id_pattern='^tunnel_[0-9A-Fa-f]{32}$'; [[ "$tunnel_id" =~ $tunnel_id_pattern && "$client" == /* && -x "$client" ]] || { print -u2 "Tunnel ID or client path is invalid."; exit 64; }; [[ -n "${CONTROL_PLANE_API_KEY:-}" && "$CONTROL_PLANE_API_KEY" != *$'\n'* ]] || { print -u2 "CONTROL_PLANE_API_KEY is required and must be one line."; exit 64; }
root="${0:A:h:h}"; private="$HOME/.messages-swift/private-tunnel"; runtime="$HOME/Library/Application Support/messages-swift/private-tunnel"; agents="$HOME/Library/LaunchAgents"; bridge="$HOME/Applications/Messages Swift.app/Contents/MacOS/messages-mcp"; wrapper="$private/messages-mcp-stdio"; key="$runtime/runtime-key"; profiles="$runtime/profiles"; health="$runtime/health.url"; logs="$runtime/logs"
[[ -x "$bridge" ]] || { print -u2 "Installed bridge is missing or not executable."; exit 66; }
mkdir -p -m 700 "$private" "$runtime" "$profiles" "$logs" "$agents"; chmod 700 "$private" "$runtime" "$profiles" "$logs"
install -m 700 "$root/scripts/private-tunnel/messages-mcp-stdio.sh" "$wrapper"; install -m 700 "$root/scripts/private-tunnel/run-private-tunnel.sh" "$private/run-private-tunnel"; install -m 700 "$root/scripts/private-tunnel/private-tunnel-service.sh" "$private/private-tunnel-service"
temporary="$runtime/.runtime-key.$$"; trap 'rm -f "$temporary"' EXIT; printf '%s' "$CONTROL_PLANE_API_KEY" > "$temporary"; chmod 600 "$temporary"; mv -f "$temporary" "$key"; trap - EXIT; unset CONTROL_PLANE_API_KEY
tunnel_label="com.ericfeunekes.messages-swift.private-tunnel"; app_label="com.ericfeunekes.messages-swift.app-supervisor"
python3 "$root/scripts/private-tunnel/create-launch-agent.py" --label "$tunnel_label" --output "$agents/$tunnel_label.plist" --stdout "$logs/tunnel.stdout.log" --stderr "$logs/tunnel.stderr.log" -- "$private/run-private-tunnel" --tunnel-client "$client" --tunnel-id "$tunnel_id" --key-file "$key" --profile-dir "$profiles" --health-url-file "$health" --mcp-command "$wrapper"
python3 "$root/scripts/private-tunnel/create-launch-agent.py" --label "$app_label" --output "$agents/$app_label.plist" --stdout "$logs/app.stdout.log" --stderr "$logs/app.stderr.log" -- /usr/bin/open -g -W "$HOME/Applications/Messages Swift.app"
service="$root/scripts/private-tunnel/private-tunnel-service.sh"; "$service" stop; "$service" start
print "Installed private Messages tunnel launch agents. Quitting Messages Swift is supervised while enabled."
