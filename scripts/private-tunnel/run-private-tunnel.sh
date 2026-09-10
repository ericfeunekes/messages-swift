#!/bin/zsh
set -euo pipefail
umask 077
usage() { print -u2 "usage: $0 --tunnel-client PATH --tunnel-id ID --key-file PATH --profile-dir PATH --health-url-file PATH --mcp-command PATH"; exit 64; }
client=""; tunnel_id=""; key_file=""; profile_dir=""; health_url_file=""; mcp_command=""
while (( $# > 0 )); do
  case "$1" in
    --tunnel-client|--tunnel-id|--key-file|--profile-dir|--health-url-file|--mcp-command) (( $# >= 2 )) || usage; case "$1" in --tunnel-client) client="$2";; --tunnel-id) tunnel_id="$2";; --key-file) key_file="$2";; --profile-dir) profile_dir="$2";; --health-url-file) health_url_file="$2";; *) mcp_command="$2";; esac; shift 2;;
    *) usage;;
  esac
done
tunnel_id_pattern='^tunnel_[0-9A-Fa-f]{32}$'; [[ "$tunnel_id" =~ $tunnel_id_pattern ]] || { print -u2 "Tunnel ID is invalid."; exit 64; }
[[ -x "$client" && -x "$mcp_command" ]] || { print -u2 "Tunnel client or MCP wrapper is missing or not executable."; exit 66; }
[[ -f "$key_file" && ! -L "$key_file" && "$(stat -f '%OLp' "$key_file")" == 600 && "$(stat -f '%u' "$key_file")" == "$(id -u)" ]] || { print -u2 "Runtime key file is missing or unsafe."; exit 77; }
CONTROL_PLANE_API_KEY="$(cat "$key_file")"; [[ -n "$CONTROL_PLANE_API_KEY" ]] || { print -u2 "Runtime key file is empty."; exit 66; }; export CONTROL_PLANE_API_KEY; unset OPENAI_API_KEY
mkdir -p -m 700 "$profile_dir" "${health_url_file:h}"; chmod 700 "$profile_dir" "${health_url_file:h}"
quoted_mcp_command="${(qq)mcp_command}"
"$client" init --sample sample_mcp_stdio_local --profile messages-stdio --profile-dir "$profile_dir" --tunnel-id "$tunnel_id" --mcp-command "$quoted_mcp_command" --control-plane-api-key-ref env:CONTROL_PLANE_API_KEY --health-listen-addr 127.0.0.1:0 --force >/dev/null
exec "$client" run --profile messages-stdio --profile-dir "$profile_dir" --health.url-file "$health_url_file"
