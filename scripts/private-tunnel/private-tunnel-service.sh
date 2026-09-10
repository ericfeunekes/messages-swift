#!/bin/zsh
set -euo pipefail
(( $# == 1 )) || { print -u2 "usage: $0 start|stop|start-app|stop-app|status|status-app"; exit 64; }
launchctl_bin="${MESSAGES_SWIFT_LAUNCHCTL_BIN:-launchctl}"; uid="$(id -u)"; agents="$HOME/Library/LaunchAgents"; tunnel="com.ericfeunekes.messages-swift.private-tunnel"; app="com.ericfeunekes.messages-swift.app-supervisor"
plist() { print -r -- "$agents/$1.plist"; }
start() { [[ -f "$(plist "$1")" ]] || { print -u2 "Private tunnel service is not installed."; exit 69; }; "$launchctl_bin" bootstrap "gui/$uid" "$(plist "$1")"; }
presence() {
  local output result_code
  output="$("$launchctl_bin" print "gui/$uid/$1" 2>&1)"; result_code=$?
  (( result_code == 0 )) && return 0
  [[ "$output" == *"Could not find service"* ]] && return 3
  print -u2 "Unable to inspect private tunnel service $1: $output"
  return "$result_code"
}
stop() {
  local result_code
  if presence "$1"; then
    "$launchctl_bin" bootout "gui/$uid/$1"
    return
  else
    result_code=$?
  fi
  (( result_code == 3 )) && return 0
  return "$result_code"
}
case "$1" in start) start "$app"; start "$tunnel";; stop) stop "$tunnel" || exit $?; stop "$app";; start-app) start "$app";; stop-app) stop "$app";; status) [[ -f "$(plist "$app")" && -f "$(plist "$tunnel")" ]] && presence "$app" && presence "$tunnel";; status-app) [[ -f "$(plist "$app")" ]] && presence "$app";; *) exit 64;; esac
