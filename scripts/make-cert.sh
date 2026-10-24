#!/bin/bash
# The self-signed code-signing identity, so that macOS keeps the toolkit's
# permissions across rebuilds (ad-hoc signatures change on every build, which
# makes TCC forget the app). Installed copies only take updates signed with it.
#
# It goes in a keychain of its own, with its own password, which build.sh
# unlocks for a day at a time (scripts/signing.sh). An identity already in the login
# keychain, as this script used to put it, is moved there: the same
# certificate and key, so installed copies and their permissions keep working.
# macOS asks for the login password to let it out, and it's taken out of the
# login keychain only once the new keychain is checked to hold the same one.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh
LOGIN="$HOME/Library/Keychains/login.keychain-db"

# The SHA-1 of the identity's certificate in a keychain, if it's there.
sha1() { security find-identity -p codesigning "$1" | awk -v name="\"$IDENTITY\"" 'index($0, name) { print $2; exit }'; }

if [[ -f "$SIGNING_KEYCHAIN" ]] && [[ -n "$(sha1 "$SIGNING_KEYCHAIN")" ]]; then
  echo "Identity '$IDENTITY' is already in $SIGNING_KEYCHAIN."
  [[ -n "$(sha1 "$LOGIN")" ]] && echo "It's in the login keychain too: once you've checked a build signs, remove it there with
  security delete-identity -Z $(sha1 "$LOGIN") \"$LOGIN\""
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS="$(/usr/bin/openssl rand -hex 24)"
OLD="$(sha1 "$LOGIN")"

if [[ -n "$OLD" ]]; then
  echo "Moving '$IDENTITY' ($OLD) out of the login keychain."
  echo "macOS will ask for your login password to export its key: that's this script."
  # `security export` can't pick one identity, so a few lines of Swift do.
  cat > "$TMP/export.swift" <<'SWIFT'
import Foundation
import Security
let name = CommandLine.arguments[1], path = CommandLine.arguments[2], out = CommandLine.arguments[3]
var keychain: SecKeychain?
guard SecKeychainOpen(path, &keychain) == errSecSuccess, let keychain else { fatalError("can't open \(path)") }
var found: CFTypeRef?
let query: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecMatchSearchList: [keychain],
                              kSecMatchLimit: kSecMatchLimitAll, kSecReturnRef: true]
guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let all = found as? [SecIdentity] else { fatalError("no identities") }
let named = all.filter { identity in
    var cert: SecCertificate?
    return SecIdentityCopyCertificate(identity, &cert) == errSecSuccess && cert.flatMap { SecCertificateCopySubjectSummary($0) as String? } == name
}
guard named.count == 1 else { fatalError("\(named.count) identities named \(name)") }
// Held until the export is done: an unretained temporary is freed before
// SecItemExport reads it, and the file gets some other password.
let passphrase = ProcessInfo.processInfo.environment["PASS"]! as CFString
var params = SecItemImportExportKeyParameters()
params.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
params.passphrase = Unmanaged.passUnretained(passphrase)
var data: CFData?
let status = withExtendedLifetime(passphrase) { SecItemExport(named[0], .formatPKCS12, [], &params, &data) }
guard status == errSecSuccess, let data else { fatalError("export failed: \(status)") }
guard FileManager.default.createFile(atPath: out, contents: data as Data, attributes: [.posixPermissions: 0o600]) else { fatalError("can't write \(out)") }
SWIFT
  if ! PASS="$PASS" swift -suppress-warnings "$TMP/export.swift" "$IDENTITY" "$LOGIN" "$TMP/id.p12" 2>"$TMP/export.log" \
      || [[ ! -s "$TMP/id.p12" ]]; then
    cat "$TMP/export.log" >&2
    echo "The identity wasn't exported; nothing was changed." >&2
    exit 1
  fi
else
  # macOS's LibreSSL, not a Homebrew OpenSSL 3+ earlier in PATH: those export
  # PKCS12 files that `security import` rejects ("MAC verification failed").
  OPENSSL=/usr/bin/openssl
  cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $IDENTITY
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
  "$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -name "$IDENTITY" -passout "pass:$PASS" 2>/dev/null
fi

if [[ ! -f "$SIGNING_KEYCHAIN" ]]; then
  echo "Choose a password for the signing keychain (build.sh asks for it about once a day)."
  security create-keychain "$SIGNING_KEYCHAIN"
else
  security unlock-keychain "$SIGNING_KEYCHAIN"
fi
# Locks itself after a day without a build.
security set-keychain-settings -u -t "$SIGNING_UNLOCKED_FOR" "$SIGNING_KEYCHAIN"
security import "$TMP/id.p12" -k "$SIGNING_KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
NEW="$(sha1 "$SIGNING_KEYCHAIN")"
security lock-keychain "$SIGNING_KEYCHAIN"

if [[ -z "$OLD" ]]; then
  echo "Created code-signing identity '$IDENTITY' ($NEW) in $SIGNING_KEYCHAIN."
elif [[ "$NEW" == "$OLD" ]]; then
  security delete-identity -Z "$OLD" "$LOGIN"
  echo "Moved '$IDENTITY' ($NEW) to $SIGNING_KEYCHAIN and removed it from the login keychain."
else
  echo "The new keychain holds '$NEW', not '$OLD'; the login keychain was left as it was." >&2
  exit 1
fi
