#!/bin/zsh
set -euo pipefail
[[ $# -eq 0 || ( $# -eq 1 && "$1" == --delete-key ) ]] || { print -u2 "usage: $0 [--delete-key]"; exit 64; }
root="${0:A:h}"; "$root/private-tunnel/private-tunnel-service.sh" stop; agents="$HOME/Library/LaunchAgents"
for label in com.ericfeunekes.messages-swift.private-tunnel com.ericfeunekes.messages-swift.app-supervisor; do rm -f "$agents/$label.plist"; done
[[ $# -eq 0 ]] || rm -f "$HOME/Library/Application Support/messages-swift/private-tunnel/runtime-key"
print "Stopped and removed private Messages tunnel launch agents."
