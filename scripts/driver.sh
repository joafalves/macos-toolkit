#!/bin/bash
# Installs the audio driver from the last build onto this Mac, or removes it, for
# development: `driver.sh install` or `driver.sh remove`. Asks for your password,
# and restarts coreaudiod, which stops all sound for a moment.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="ToolkitAudio.driver"
HAL="/Library/Audio/Plug-Ins/HAL"
BUILT="build/MacOS Toolkit.app/Contents/Resources/$NAME"

case "${1:-}" in
  install)
    [ -d "$BUILT" ] || { echo "no driver in build/: run scripts/build.sh first" >&2; exit 1; }
    codesign -v "$BUILT"
    sudo rm -rf "${HAL:?}/$NAME"
    sudo ditto "$BUILT" "$HAL/$NAME"
    sudo chown -R root:wheel "$HAL/$NAME"
    ;;
  remove)
    sudo rm -rf "${HAL:?}/$NAME"
    ;;
  *)
    echo "usage: $0 install|remove" >&2
    exit 1
    ;;
esac
sudo killall coreaudiod
echo "Done: coreaudiod restarted."
