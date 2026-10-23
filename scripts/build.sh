#!/bin/bash
# Builds "MacOS Toolkit.app" into ./build. Pass --install to copy it to
# /Applications and (re)launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${TOOLKIT_IDENTITY:-MacOS Toolkit Dev}"
BUNDLE_ID="dev.jalves.macos-toolkit"
APP="build/MacOS Toolkit.app"
APPEX="$APP/Contents/PlugIns/FinderExtension.appex"
INSTALLED="/Applications/MacOS Toolkit.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Toolkit "$APP/Contents/MacOS/Toolkit"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The commit it's built from, for About, and whether the tree had changes
# on top of it: then the commit alone isn't what was built.
if COMMIT="$(git rev-parse --short HEAD 2>/dev/null)"; then
  /usr/libexec/PlistBuddy -c "Add :ToolkitCommit string $COMMIT" "$APP/Contents/Info.plist"
  [ -n "$(git status --porcelain)" ] && MODIFIED=true || MODIFIED=false
  /usr/libexec/PlistBuddy -c "Add :ToolkitModified bool $MODIFIED" "$APP/Contents/Info.plist"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The translations; English is the code's own text.
cp -R Resources/*.lproj "$APP/Contents/Resources/"

# The Finder extension, with the app's version so the two never disagree.
mkdir -p "$APPEX/Contents/MacOS"
cp .build/release/FinderExtension "$APPEX/Contents/MacOS/FinderExtension"
cp Resources/FinderExtension/Info.plist "$APPEX/Contents/Info.plist"
mkdir -p "$APPEX/Contents/Resources"
cp -R Resources/FinderExtension/*.lproj "$APPEX/Contents/Resources/"
for key in CFBundleShortVersionString CFBundleVersion; do
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" Resources/Info.plist)"
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$APPEX/Contents/Info.plist"
done

if ! security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
  echo "warning: identity '$IDENTITY' not found (run scripts/make-cert.sh); signing ad-hoc." >&2
  IDENTITY="-"
fi
# Inside out: the extension first, since the app's signature covers it.
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID.finder" \
  --entitlements Resources/FinderExtension/FinderExtension.entitlements "$APPEX"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Toolkit 2>/dev/null && sleep 0.5 || true
  rm -rf "$INSTALLED"
  ditto "$APP" "$INSTALLED"
  # Finder keeps using the old extension, and replacing it under Finder can
  # leave two copies loaded (every menu item twice) or none. A fresh Finder
  # loads the new one once; its windows come back.
  if pluginkit -m -i "$BUNDLE_ID.finder" | grep -q '^+'; then
    pkill -f "FinderExtension.appex" 2>/dev/null || true
    killall Finder 2>/dev/null || true
  fi
  open "$INSTALLED"
  echo "Installed and launched $INSTALLED"
fi
