#!/bin/zsh
# Compile Tézeu et fabrique build/Tezeu.app, signée avec le certificat local « Tezeu Dev ».
# Variables facultatives (utilisées par la GitHub Action de release) :
#   SIGN_IDENTITY : identité de signature (« - » = signature ad hoc, sans certificat)
#   VERSION       : numéro de version écrit dans l'app (ex. 0.2.0)
set -euo pipefail
SIGN_IDENTITY="${SIGN_IDENTITY:-Tezeu Dev}"
cd "$(dirname "$0")"

./scripts/fetch-whisper.sh
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Tezeu"

APP=build/Tezeu.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Tezeu"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns Resources/MenuBarIcon.svg "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Frameworks"
ditto Vendor/whisper.xcframework/macos-arm64_x86_64/whisper.framework "$APP/Contents/Frameworks/whisper.framework"
if [[ -n "${VERSION:-}" ]]; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
fi

# Même certificat à chaque compilation = macOS garde les autorisations.
codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/whisper.framework"
codesign --force --sign "$SIGN_IDENTITY" "$APP"
echo "OK : $APP"
