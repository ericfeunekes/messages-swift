#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
build_root="$repo_root/.build/release"
mkdir -p "$repo_root/.scratch"
staging_root="$(mktemp -d "$repo_root/.scratch/install-menu-app.XXXXXX")"
app_name="Messages Swift.app"
staged_app="$staging_root/$app_name"
destination_root="$HOME/Applications"
destination_app="$destination_root/$app_name"

cleanup() {
  rm -rf "$staging_root"
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
# Contacts access under its own identity; it does not alter TCC, Full Disk Access, or quarantine state.
codesign --force --sign - --options runtime --entitlements "$repo_root/packaging/MessagesSwift.entitlements" "$staged_app/Contents/MacOS/Messages Swift"
codesign --force --sign - --options runtime "$staged_app/Contents/MacOS/messages-mcp"
codesign --force --sign - --options runtime --entitlements "$repo_root/packaging/MessagesSwift.entitlements" "$staged_app"
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
  if pgrep -x "Messages Swift" >/dev/null; then
    print -u2 "Quit Messages Swift before installing an update."
    exit 1
  fi
fi
rm -rf "$destination_app"
ditto "$staged_app" "$destination_app"
echo "Installed $destination_app"
