#!/bin/bash
# Builds "MacOS Toolkit.app" into ./build. Pass --install to copy it to
# /Applications and (re)launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${TOOLKIT_IDENTITY:-MacOS Toolkit Dev}"
BUNDLE_ID="dev.jalves.macos-toolkit"
APP="build/MacOS Toolkit.app"
INSTALLED="/Applications/MacOS Toolkit.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Toolkit "$APP/Contents/MacOS/Toolkit"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
  echo "warning: identity '$IDENTITY' not found (run scripts/make-cert.sh); signing ad-hoc." >&2
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Toolkit 2>/dev/null && sleep 0.5 || true
  rm -rf "$INSTALLED"
  ditto "$APP" "$INSTALLED"
  open "$INSTALLED"
  echo "Installed and launched $INSTALLED"
fi
