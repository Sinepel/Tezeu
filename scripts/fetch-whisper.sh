#!/bin/zsh
# Télécharge whisper.cpp (version compilée officielle, licence MIT) dans Vendor/ et vérifie son empreinte.
# Lancé automatiquement par build.sh si Vendor/whisper.xcframework est absent.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=b5454 # whisper.cpp v1.9.5
SHA256=e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b
URL="https://github.com/ggml-org/whisper.cpp/releases/download/$VERSION/whisper-$VERSION-xcframework.zip"

if [[ -d Vendor/whisper.xcframework ]]; then
    echo "whisper.cpp déjà présent."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Téléchargement de whisper.cpp $VERSION (66 Mo) depuis GitHub…"
curl -fL --progress-bar -o "$TMP/whisper.zip" "$URL"
echo "$SHA256  $TMP/whisper.zip" | shasum -a 256 -c -
ditto -x -k "$TMP/whisper.zip" "$TMP/x"
mkdir -p Vendor
mv "$TMP/x/build-apple/whisper.xcframework" Vendor/
echo "whisper.cpp installé dans Vendor/."
