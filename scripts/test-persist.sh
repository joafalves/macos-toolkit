#!/bin/bash
# Window Layout keeps what it snapped across a restart of the app: a quit,
# a kill, and a crash (kill -9). Uses the installed app, which it restarts,
# and a helper's windows, which it drags (leave the mouse alone).
#   ./scripts/build.sh --install && ./scripts/test-persist.sh
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/MacOS Toolkit.app"
INSTALLED="/Applications/MacOS Toolkit.app"
BUNDLE_ID=dev.jalves.macos-toolkit
OUT="$(mktemp -d -t macos-toolkit-persist-test)"
TRACE="$OUT/trace.txt"

# The helper's windows live through the restarts: started on its own, from
# a copy with another bundle ID, or the app, started again, would see itself
# already running and leave.
HELPER_APP="$OUT/Helper.app"
ditto "$APP" "$HELPER_APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID.helper" "$HELPER_APP/Contents/Info.plist"
rm -rf "$HELPER_APP/Contents/PlugIns"
codesign --force --sign - "$HELPER_APP" 2>/dev/null
"$HELPER_APP/Contents/MacOS/Toolkit" --layout-test-window --regular &
HELPER=$!
sleep 2
cleanup() {
  kill "$HELPER" 2>/dev/null || true
  defaults delete "$BUNDLE_ID" layoutTrace 2>/dev/null || true
  pgrep -f "$INSTALLED/Contents/MacOS/Toolkit" >/dev/null || open "$INSTALLED"
  rm -rf "$OUT"
}
trap cleanup EXIT

# The app reads the trace setting at launch: started again with it.
defaults write "$BUNDLE_ID" layoutTrace "$TRACE"
# Only the installed app: the helper and the test steps run the same binary.
installed() { pgrep -f "$INSTALLED/Contents/MacOS/Toolkit"; }
restart() { # how
  case "$1" in
    quit) osascript -e "tell application id \"$BUNDLE_ID\" to quit" ;;
    kill) kill "$(installed)" ;;
    crash) kill -9 "$(installed)" ;;
  esac
  while pgrep -f "$INSTALLED/Contents/MacOS/Toolkit" >/dev/null; do sleep 0.2; done
  open "$INSTALLED"
  sleep 4
}
step() { # name
  open -n -W "$APP" --args --test-persist "$1" "$HELPER" "$OUT/$1.txt"
  grep -v "^all passed" "$OUT/$1.txt" || true
}
restart quit
sleep 2
for how in quit kill crash; do
  echo "-- restarted by $how"
  step snap
  sleep 2    # past the save, a second after the last change
  restart "$how"
  step check
done
echo "-- moved while the app was quit"
step snap
sleep 2
osascript -e "tell application id \"$BUNDLE_ID\" to quit"
while pgrep -f "$INSTALLED/Contents/MacOS/Toolkit" >/dev/null; do sleep 0.2; done
step move
open "$INSTALLED"
sleep 4
step moved
echo "-- what the app said at each launch"
grep "placements kept\|placements from before" "$TRACE" || echo "nothing"
