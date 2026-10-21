#!/bin/bash
# Creates a self-signed code-signing certificate in the login keychain so that
# macOS keeps the Accessibility grant across rebuilds (ad-hoc signatures change
# on every build, which makes TCC forget the app). Shared by every tool in this repo.
set -euo pipefail
NAME="${1:-MacOS Toolkit Dev}"

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "Identity '$NAME' already exists."
  exit 0
fi

# macOS's LibreSSL, not a Homebrew OpenSSL 3+ earlier in PATH: those export
# PKCS12 files that `security import` rejects ("MAC verification failed").
OPENSSL=/usr/bin/openssl

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -name "$NAME" -passout pass:toolkit 2>/dev/null
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P toolkit -T /usr/bin/codesign
echo "Created code-signing identity '$NAME'."
