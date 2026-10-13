#!/bin/bash
# Builds Tiller.app into ./build. Pass --install to copy it to /Applications
# and (re)launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${TOOLKIT_IDENTITY:-MacOS Toolkit Dev}"
APP="build/Tiller.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Tiller "$APP/Contents/MacOS/Tiller"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" --identifier dev.jalves.tiller "$APP"
else
  echo "warning: identity '$IDENTITY' not found (run scripts/make-cert.sh from the repo root); signing ad-hoc." >&2
  codesign --force --sign - --identifier dev.jalves.tiller "$APP"
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Tiller 2>/dev/null && sleep 0.5 || true
  rm -rf /Applications/Tiller.app
  ditto "$APP" /Applications/Tiller.app
  open /Applications/Tiller.app
  echo "Installed and launched /Applications/Tiller.app"
fi
