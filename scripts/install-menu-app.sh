#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
build_root="$repo_root/.build/release"
mkdir -p "$repo_root/.scratch"
staging_root="$(mktemp -d "$repo_root/.scratch/install-menu-app.XXXXXX")"
app_name="Messages Swift.app"
signing_identity_file="$HOME/Library/Application Support/messages-swift/signing-identity"
if [[ -n "${MESSAGES_SWIFT_SIGNING_IDENTITY:-}" ]]; then
  signing_identity="$MESSAGES_SWIFT_SIGNING_IDENTITY"
elif [[ -f "$signing_identity_file" ]]; then
  IFS= read -r signing_identity < "$signing_identity_file"
  [[ -n "$signing_identity" ]] || { print -u2 "Signing identity file is empty."; exit 1; }
else
  signing_identity="-"
fi
staged_app="$staging_root/$app_name"
destination_root="$HOME/Applications"
destination_app="$destination_root/$app_name"
private_service="$repo_root/scripts/private-tunnel/private-tunnel-service.sh"
resume_private_supervisor=false

cleanup() {
  local original_status=$?
  if $resume_private_supervisor; then
    if ! "$private_service" start-app >/dev/null 2>&1; then
      print -u2 "Failed to resume the private Messages app supervisor."
      (( original_status == 0 )) && return 1
    fi
  fi
  rm -rf "$staging_root"
  return "$original_status"
}
trap cleanup EXIT

cd "$repo_root"
swift build -c release --product "Messages Swift"
swift build -c release --product messages-mcp

mkdir -p "$staged_app/Contents/MacOS"
cp "$repo_root/packaging/Info.plist" "$staged_app/Contents/Info.plist"
install -m 755 "$build_root/Messages Swift" "$staged_app/Contents/MacOS/Messages Swift"
install -m 755 "$build_root/messages-mcp" "$staged_app/Contents/MacOS/messages-mcp"

# Sign executable code before the enclosing bundle. This allows the app to request
# Contacts and Automation access under its own identity; it does not alter TCC,
# Full Disk Access, or quarantine state.
codesign --force --sign "$signing_identity" --options runtime "$staged_app/Contents/MacOS/messages-mcp"
codesign --force --sign "$signing_identity" --options runtime --entitlements "$repo_root/packaging/MessagesSwift.entitlements" "$staged_app/Contents/MacOS/Messages Swift"
codesign --force --sign "$signing_identity" --options runtime --entitlements "$repo_root/packaging/MessagesSwift.entitlements" "$staged_app"
codesign --verify --deep --strict --verbose=2 "$staged_app"

mkdir -p "$destination_root"
if [[ -e "$destination_app" ]]; then
  if [[ -L "$destination_app" ]] || [[ ! -f "$destination_app/Contents/Info.plist" ]]; then
    print -u2 "Refusing to replace an unexpected destination: $destination_app"
    exit 1
  fi
  existing_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination_app/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$existing_bundle_id" != "com.ericfeunekes.messages-swift" ]]; then
    print -u2 "Refusing to replace an app with a different bundle identifier."
    exit 1
  fi
  if [[ -x "$private_service" ]]; then
    "$private_service" status-app >/dev/null 2>&1
    service_status=$?
    if (( service_status == 0 )); then
      "$private_service" stop-app
      resume_private_supervisor=true
    elif (( service_status != 3 )); then
      print -u2 "Unable to determine whether the private Messages app supervisor is loaded."
      exit "$service_status"
    fi
  fi
  if pgrep -x "Messages Swift" >/dev/null; then
    if $resume_private_supervisor; then
      /usr/bin/killall -TERM "Messages Swift" >/dev/null 2>&1 || true
      for _ in {1..50}; do
        pgrep -x "Messages Swift" >/dev/null || break
        sleep 0.1
      done
      if pgrep -x "Messages Swift" >/dev/null; then
        print -u2 "Messages Swift did not stop for the supervised update."
        exit 1
      fi
    else
      print -u2 "Quit Messages Swift before installing an update."
      exit 1
    fi
  fi
fi
rm -rf "$destination_app"
ditto "$staged_app" "$destination_app"
echo "Installed $destination_app"
