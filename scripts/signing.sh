# Sourced by build.sh and test-update.sh: finds the signing identity and
# unlocks its keychain if it's locked. signing_start also puts that keychain
# on the user's search list, where codesign looks, so a caller follows its
# signing with signing_end (and traps it on EXIT) to take it off again.
#
# One build signs at a time: several can run at once (agents share the
# worktree), and the first to finish would take the keychain off the list
# while another is still signing, which then finds no identity. A lock file
# with the holder's PID (shlock) keeps them in turn; one whose holder died
# counts as free.
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
# Whether signing_start put the signing keychain on the search list.
SIGNING_LISTED=false
SIGNING_LOCK="${TMPDIR:-/tmp}/macos-toolkit-signing.lock"
SIGNING_LOCKED=false

# Waits for any other build's signing to finish, up to five minutes.
signing_lock() {
  local waited=0
  until shlock -f "$SIGNING_LOCK" -p $$; do
    (( waited % 50 == 0 )) && echo "Waiting for another build to finish signing." >&2
    (( waited >= 3000 )) && { echo "error: another build has been signing for five minutes ($SIGNING_LOCK)." >&2; exit 1; }
    sleep 0.1
    waited=$((waited + 1))
  done
  SIGNING_LOCKED=true
}

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
  signing_lock
  if [[ -f "$SIGNING_KEYCHAIN" ]] && security find-identity -p codesigning "$SIGNING_KEYCHAIN" | grep -q "\"$IDENTITY\""; then
    if ! signing_unlocked; then
      echo "Unlocking the signing keychain ($(basename "$SIGNING_KEYCHAIN")) for 24 hours."
      security unlock-keychain "$SIGNING_KEYCHAIN"
    fi
    # Not on sleep: every lid closed would ask again. Each build starts the 24 hours over.
    security set-keychain-settings -u -t "$SIGNING_UNLOCKED_FOR" "$SIGNING_KEYCHAIN"
    SIGN_ARGS=(--keychain "$SIGNING_KEYCHAIN")
    # codesign only finds an identity in a keychain on the search list,
    # --keychain or not (measured): it goes on the list while signing, and
    # signing_end takes it off again.
    local list=()
    signing_list list
    if ! printf '%s\n' ${list[@]+"${list[@]}"} | grep -qxF "$SIGNING_KEYCHAIN"; then
      security list-keychains -d user -s ${list[@]+"${list[@]}"} "$SIGNING_KEYCHAIN"
      SIGNING_LISTED=true
    fi
  elif security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    echo "warning: '$IDENTITY' is in the login keychain, where any process can sign with it." >&2
    echo "         Run scripts/make-cert.sh to move it to a keychain of its own." >&2
  else
    echo "warning: identity '$IDENTITY' not found (run scripts/make-cert.sh); signing ad-hoc." >&2
    IDENTITY="-"
  fi
}

# The user's keychain search list, one path each, into the array named $1.
signing_list() {
  local entry
  eval "$1=()"
  while IFS= read -r entry; do eval "$1+=(\"\$entry\")"; done \
    < <(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"$//')
}

# Once the signing is done (and on exit, if it fails): the signing keychain
# off the search list, if signing_start put it there, and the lock let go.
# Only that keychain comes off, so one added to the list meanwhile stays.
signing_end() {
  if $SIGNING_LISTED; then
    local list=() rest=() entry
    signing_list list
    for entry in ${list[@]+"${list[@]}"}; do
      [[ "$entry" != "$SIGNING_KEYCHAIN" ]] && rest+=("$entry")
    done
    security list-keychains -d user -s ${rest[@]+"${rest[@]}"}
    SIGNING_LISTED=false
  fi
  if $SIGNING_LOCKED; then
    rm -f "$SIGNING_LOCK"
    SIGNING_LOCKED=false
  fi
}
