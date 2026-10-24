#!/bin/bash
# The updater against made-up releases, made from the current build and
# served from this Mac: one signed with the local identity, one changed after
# signing, one signed ad hoc, one older. Nothing is published, and GitHub
# isn't asked. Installs over a copy of the app in a temporary folder.
#   ./scripts/build.sh --dev && ./scripts/test-update.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh
REPO="$PWD"
OUT="$(mktemp -d -t macos-toolkit-update-test)"
trap 'rm -rf "$OUT"' EXIT
PORT=8765
BUNDLE_ID=dev.jalves.macos-toolkit
APP="$REPO/build/MacOS Toolkit.app"
# --test-update is a development flag.
if [[ "$(/usr/libexec/PlistBuddy -c "Print :ToolkitDev" "$APP/Contents/Info.plist" 2>/dev/null)" != true ]]; then
  echo "Build with ./scripts/build.sh --dev first." >&2; exit 1
fi
mkdir -p "$OUT/feeds" "$OUT/target" "$OUT/work"

# name, version, identity, changed after signing. Signed as build.sh signs.
release() {
  local keychain=()
  [[ "$3" != - ]] && keychain=(${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"})
  local dir="$OUT/work/$1" app="$OUT/work/$1/MacOS Toolkit.app"
  mkdir -p "$dir"
  ditto "$APP" "$app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $2" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $2" "$app/Contents/PlugIns/FinderExtension.appex/Contents/Info.plist"
  codesign --force --sign "$3" ${keychain[@]+"${keychain[@]}"} --options runtime --identifier "$BUNDLE_ID.finder" \
    --entitlements Resources/FinderExtension/FinderExtension.entitlements "$app/Contents/PlugIns/FinderExtension.appex" 2>/dev/null
  codesign --force --sign "$3" ${keychain[@]+"${keychain[@]}"} --options runtime --identifier "$BUNDLE_ID" \
    --entitlements Resources/Toolkit.entitlements "$app" 2>/dev/null
  if [[ "$4" == yes ]]; then echo changed >> "$app/Contents/Resources/$(ls "$app/Contents/Resources" | head -1)"; fi
  (cd "$dir" && ditto -c -k --keepParent --norsrc "MacOS Toolkit.app" "$OUT/feeds/MacOS-Toolkit-$2.zip")
  cat > "$OUT/feeds/$1.json" <<JSON
{"tag_name": "v$2", "html_url": "https://example.invalid/release",
 "body": "### Fixed\n\n- **Window Layout:** something.\n\n## Install\n\nunzip",
 "assets": [{"name": "MacOS-Toolkit-$2.zip", "browser_download_url": "http://127.0.0.1:$PORT/MacOS-Toolkit-$2.zip"}]}
JSON
}
signing_start
release good 0.99.0 "$IDENTITY" no
release tampered 0.99.1 "$IDENTITY" yes
release adhoc 0.99.2 - no
release old 0.17.0 "$IDENTITY" no
signing_end
ditto "$APP" "$OUT/target/MacOS Toolkit.app"

(cd "$OUT/feeds" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SERVER=$!
disown $SERVER
trap 'kill $SERVER 2>/dev/null; rm -rf "$OUT"' EXIT
sleep 1
open -n -W "$APP" --args --test-update "http://127.0.0.1:$PORT" "$OUT/target/MacOS Toolkit.app" "$OUT/report.txt"
cat "$OUT/report.txt"
codesign --verify --deep --strict "$OUT/target/MacOS Toolkit.app" && echo "codesign: the installed copy is valid"
