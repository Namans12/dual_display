#!/bin/bash
# Creates the self-signed code-signing identity used by build-dmg.sh, once.
#
# Why: without a paid Apple Developer ID the app can only be ad-hoc signed, and
# macOS ties privacy grants (Screen Recording, Accessibility, Local Network) of
# an ad-hoc app to the exact build. Every rebuild then becomes a "new" app to
# macOS: the old grant stops working but stays listed, switched on. Signing every
# build with the same certificate gives the app one stable identity, so a grant
# survives updates and there is one entry per list.
#
# The certificate is self-signed: Gatekeeper still shows the "unidentified
# developer" warning on first open (right-click > Open). Its private key lives
# in your login keychain; whoever holds it can sign builds that macOS treats as
# this app, so keep it private, and back it up if you want to keep releasing
# updates that inherit existing grants.
set -euo pipefail

NAME="${EXTDISPLAY_SIGN_IDENTITY:-Extended Display Self-Signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Signing certificate \"$NAME\" already exists in the login keychain."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$WORK/cert.conf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
# A throwaway passphrase only protects the file for the seconds it exists.
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/identity.p12" -passout "pass:$PASS" 2>/dev/null
# -T: let codesign use the key (macOS may still ask once; choose "Always Allow").
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Created signing certificate \"$NAME\" in the login keychain (valid 10 years)."
