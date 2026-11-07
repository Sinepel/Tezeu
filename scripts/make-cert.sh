#!/bin/zsh
# Crée une seule fois le certificat local « Tezeu Dev » dans le trousseau de session.
# Il sert uniquement à signer Tézeu sur ce Mac. Il ne quitte pas le Mac.
set -euo pipefail

NAME="Tezeu Dev"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "Le certificat « $NAME » existe déjà."
else
PASS="$(openssl rand -hex 16)"

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=$NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null

# Format p12 « legacy » : le seul que le trousseau macOS sait lire.
openssl pkcs12 -export -legacy -name "$NAME" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout "pass:$PASS"

security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db \
    -P "$PASS" -T /usr/bin/codesign
echo "Certificat « $NAME » créé."
fi

# Marque le certificat comme fiable pour signer du code, pour ton compte seulement.
# macOS affiche une fenêtre qui demande ton mot de passe : lance ce script dans Terminal.app.
if ! security find-identity -v -p codesigning | grep -q "$NAME"; then
    security find-certificate -c "$NAME" -p > "$TMP/cert.pem"
    security add-trusted-cert -r trustRoot -p codeSign \
        -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem"
fi
security find-identity -v -p codesigning | grep "$NAME" && echo "Prêt pour signer."
