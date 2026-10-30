#!/bin/bash
# Builds "MacOS Toolkit.app" into ./build. Pass --install to copy it to
# /Applications and (re)launch it, and --dev for a build with the development
# flags (main.swift), which the tests run through the app bundle need. Never
# publish or keep one installed: any process can use those flags with the
# app's permissions.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh

INSTALL=false DEV=false
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=true ;;
    --dev) DEV=true ;;
    *) echo "usage: $0 [--dev] [--install]" >&2; exit 1 ;;
  esac
done

BUNDLE_ID="dev.jalves.macos-toolkit"
APP="build/MacOS Toolkit.app"
APPEX="$APP/Contents/PlugIns/FinderExtension.appex"
INSTALLED="/Applications/MacOS Toolkit.app"

if $DEV; then swift build -c release -Xswiftc -DTOOLKIT_DEV; else swift build -c release; fi

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
# For the test scripts, which need the flags.
$DEV && /usr/libexec/PlistBuddy -c "Add :ToolkitDev bool true" "$APP/Contents/Info.plist"
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

signing_start
trap signing_end EXIT
# The audio driver, in the app's Resources, and installed from there. Only a
# process signed like this gets the driver's shared memory: an ad-hoc build
# has no certificate to name, so its driver goes by the identifier alone.
DRIVER="$APP/Contents/Resources/ToolkitAudio.driver"
if [ "$IDENTITY" = "-" ]; then
  REQUIREMENT="identifier \\\"$BUNDLE_ID\\\""
else
  LEAF="$(security find-certificate -c "$IDENTITY" -Z "$SIGNING_KEYCHAIN" 2>/dev/null | awk '/^SHA-1 hash:/ { print $3; exit }')"
  REQUIREMENT="identifier \\\"$BUNDLE_ID\\\" and certificate leaf = H\\\"$LEAF\\\""
fi
mkdir -p "$DRIVER/Contents/MacOS"
clang -bundle -arch arm64 -O2 -Wall -Wextra -mmacosx-version-min=15.0 -ISources/DriverShared/include \
  -DTOOLKIT_REQUIREMENT="\"$REQUIREMENT\"" -fvisibility=hidden \
  -framework CoreAudio -framework CoreFoundation -framework Security \
  -o "$DRIVER/Contents/MacOS/ToolkitAudio" Driver/ToolkitAudio.c
# A version of its own, not the app's: installing one takes a password and
# stops all sound for a moment, so only a change to the driver may ask for it.
cp Driver/Info.plist "$DRIVER/Contents/Info.plist"
codesign --force --sign "$IDENTITY" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} --options runtime --identifier "$BUNDLE_ID.audio" "$DRIVER"
# Inside out: the extension first, since the app's signature covers it. The
# hardened runtime keeps other processes from loading code into the app
# (DYLD_INSERT_LIBRARIES, a debugger) and using its permissions.
codesign --force --sign "$IDENTITY" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} --options runtime --identifier "$BUNDLE_ID.finder" \
  --entitlements Resources/FinderExtension/FinderExtension.entitlements "$APPEX"
codesign --force --sign "$IDENTITY" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} --options runtime --identifier "$BUNDLE_ID" \
  --entitlements Resources/Toolkit.entitlements "$APP"
signing_end
echo "Built $APP$($DEV && echo " (dev build, with the development flags)")"

if $INSTALL; then
  $DEV && echo "warning: installing a dev build: other processes can use its flags with the app's permissions. Install a plain build when done." >&2
  # Only the installed app: a dev build running a test elsewhere is a Toolkit too.
  RUNNING="^$INSTALLED/Contents/MacOS/Toolkit"
  if pkill -f "$RUNNING" 2>/dev/null; then
    for _ in {1..50}; do pgrep -qf "$RUNNING" || break; sleep 0.1; done
  fi
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
