#!/usr/bin/env bash
#
# One-time setup on the Mac you publish releases from. Run it once, ever:
#
#   macos/OpenClicky/scripts/setup-release-keys.sh
#
# 1. A self-signed code-signing certificate ("OpenClicky Self-Signed", 10 years) in your login
#    keychain, so every build carries the same signature and macOS keeps its permissions across
#    updates. No Apple Developer account needed.
# 2. Sparkle's EdDSA update key (private half in the keychain), with the public half written to
#    Info.plist. Each copy of the app only installs updates signed by this key. Commit that change.
#
# Back both up: losing the update key means every installed copy has to be replaced by hand.
#
# OPENCLICKY_KEYCHAIN picks another keychain, which is how this was tested.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NAME="OpenClicky Self-Signed"
KEYCHAIN="${OPENCLICKY_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "▸ '$NAME' is already in the keychain; keeping it"
else
  echo "▸ making the '$NAME' certificate"
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  cat > "$WORK/cert.cnf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
  PASSWORD="$(/usr/bin/openssl rand -hex 16)"
  /usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/identity.p12" -passout "pass:$PASSWORD" -name "$NAME"
  security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
fi

GENERATE_KEYS="$(find "$APP_DIR/build/DerivedData/SourcePackages/artifacts/sparkle" "$HOME/Library/Developer/Xcode/DerivedData" -type f -name generate_keys -perm -u+x 2>/dev/null | head -1 || true)"
if [[ -z "$GENERATE_KEYS" ]]; then
  echo "▸ Sparkle's tools aren't built yet: run scripts/release.sh --no-install once, then run this again." >&2
  exit 1
fi
echo "▸ Sparkle update key (macOS may ask to use the keychain)"
"$GENERATE_KEYS" >/dev/null
PUBLIC_KEY="$("$GENERATE_KEYS" -p)"
[[ -n "$PUBLIC_KEY" ]] || { echo "no public key came back from generate_keys" >&2; exit 1; }
/usr/bin/plutil -replace SUPublicEDKey -string "$PUBLIC_KEY" "$APP_DIR/OpenClicky/Info.plist"
echo "▸ done. Commit OpenClicky/Info.plist, then publish with scripts/release.sh --publish"
