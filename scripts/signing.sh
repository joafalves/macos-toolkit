# Sourced by build.sh and test-update.sh: finds the signing identity and
# unlocks its keychain for as long as the script runs.
#
# The identity lives in a keychain of its own, with its own password, locked
# except while signing (scripts/make-cert.sh). In the login keychain, which is
# always unlocked, any process could sign its own code as the toolkit with it,
# and macOS would give that code the toolkit's permissions.

IDENTITY="${TOOLKIT_IDENTITY:-MacOS Toolkit Dev}"
SIGNING_KEYCHAIN="${TOOLKIT_KEYCHAIN:-$HOME/Library/Keychains/macos-toolkit-signing.keychain-db}"
# Passed to codesign; empty when signing ad hoc.
SIGN_ARGS=()

signing_start() {
  if [[ -f "$SIGNING_KEYCHAIN" ]] && security find-identity -p codesigning "$SIGNING_KEYCHAIN" | grep -q "\"$IDENTITY\""; then
    echo "Unlocking the signing keychain ($(basename "$SIGNING_KEYCHAIN"))."
    security unlock-keychain "$SIGNING_KEYCHAIN"
    trap 'signing_end' EXIT
    SIGN_ARGS=(--keychain "$SIGNING_KEYCHAIN")
  elif security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    echo "warning: '$IDENTITY' is in the login keychain, where any process can sign with it." >&2
    echo "         Run scripts/make-cert.sh to move it to a keychain of its own." >&2
  else
    echo "warning: identity '$IDENTITY' not found (run scripts/make-cert.sh); signing ad-hoc." >&2
    IDENTITY="-"
  fi
}

# Also on exit; scripts that set their own EXIT trap call it there too. The
# keychain locks itself after a few minutes anyway.
signing_end() {
  [[ ${#SIGN_ARGS[@]} -gt 0 ]] && security lock-keychain "$SIGNING_KEYCHAIN" 2>/dev/null
  return 0
}
