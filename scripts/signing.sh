# Sourced by build.sh and test-update.sh: finds the signing identity and
# unlocks its keychain if it's locked.
#
# The identity lives in a keychain of its own, with its own password
# (scripts/make-cert.sh). In the login keychain, which is always unlocked,
# any process could sign its own code as the toolkit with it, and macOS would
# give that code the toolkit's permissions. Once unlocked it stays so until
# 24 hours pass without a build, so the password is asked about once a day:
# while it's unlocked, anything running as you could sign with it too.

IDENTITY="${TOOLKIT_IDENTITY:-MacOS Toolkit Dev}"
SIGNING_KEYCHAIN="${TOOLKIT_KEYCHAIN:-$HOME/Library/Keychains/macos-toolkit-signing.keychain-db}"
# Seconds without use before it locks itself.
SIGNING_UNLOCKED_FOR=86400
# Passed to codesign; empty when signing ad hoc.
SIGN_ARGS=()

# SecKeychainGetStatus, which `security` doesn't offer: unlock-keychain asks
# for the password even when it's already unlocked.
signing_unlocked() {
  python3 -c '
import ctypes, sys
security = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/Security.framework/Security")
keychain, status = ctypes.c_void_p(), ctypes.c_uint32()
ok = security.SecKeychainOpen(sys.argv[1].encode(), ctypes.byref(keychain)) == 0 \
    and security.SecKeychainGetStatus(keychain, ctypes.byref(status)) == 0
sys.exit(0 if ok and status.value & 1 else 1)  # kSecUnlockStateStatus
' "$SIGNING_KEYCHAIN"
}

signing_start() {
  if [[ -f "$SIGNING_KEYCHAIN" ]] && security find-identity -p codesigning "$SIGNING_KEYCHAIN" | grep -q "\"$IDENTITY\""; then
    if ! signing_unlocked; then
      echo "Unlocking the signing keychain ($(basename "$SIGNING_KEYCHAIN")) for 24 hours."
      security unlock-keychain "$SIGNING_KEYCHAIN"
    fi
    # Not on sleep: every lid closed would ask again. Each build starts the 24 hours over.
    security set-keychain-settings -u -t "$SIGNING_UNLOCKED_FOR" "$SIGNING_KEYCHAIN"
    SIGN_ARGS=(--keychain "$SIGNING_KEYCHAIN")
  elif security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    echo "warning: '$IDENTITY' is in the login keychain, where any process can sign with it." >&2
    echo "         Run scripts/make-cert.sh to move it to a keychain of its own." >&2
  else
    echo "warning: identity '$IDENTITY' not found (run scripts/make-cert.sh); signing ad-hoc." >&2
    IDENTITY="-"
  fi
}
