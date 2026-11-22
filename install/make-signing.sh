#!/bin/sh
# Creates (once) a local code-signing identity for Boss.app in its own keychain, no admin needed.
# A stable signature keeps macOS permission grants (Microphone, Input Monitoring) across updates.
#   sh install/make-signing.sh <dir>      prints the identity hash
set -eu
DIR="$1"
KC="$DIR/boss-signing.keychain-db"
PASS="$DIR/keychain.pass"
OSSL=/usr/bin/openssl
mkdir -p "$DIR"; chmod 700 "$DIR"
if [ ! -f "$KC" ]; then
  ( umask 077; $OSSL rand -hex 16 | tr -d '\n' > "$PASS" )
  security create-keychain -p "$(cat "$PASS")" "$KC"
  security set-keychain-settings "$KC"          # no auto-lock
  T="$(mktemp -d)"
  cat > "$T/c.cnf" <<'CNF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Boss Local Signing
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
CNF
  $OSSL req -x509 -newkey rsa:2048 -nodes -keyout "$T/k.pem" -out "$T/c.pem" -days 3650 -config "$T/c.cnf" 2>/dev/null
  P="$($OSSL rand -hex 12)"
  $OSSL pkcs12 -export -inkey "$T/k.pem" -in "$T/c.pem" -out "$T/b.p12" -passout "pass:$P" 2>/dev/null
  security unlock-keychain -p "$(cat "$PASS")" "$KC"
  security import "$T/b.p12" -k "$KC" -P "$P" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(cat "$PASS")" "$KC" >/dev/null 2>&1
  rm -rf "$T"
fi
security unlock-keychain -p "$(cat "$PASS")" "$KC"
# codesign looks only at keychains in the search list: add ours, keep everything already there.
CUR="$(security list-keychains -d user | sed 's/^[[:space:]]*"//; s/"$//')"
echo "$CUR" | grep -qF "$KC" || security list-keychains -d user -s $CUR "$KC"
security find-identity -p codesigning "$KC" | awk '/1\)/{print $2; exit}'
