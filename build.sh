#!/bin/zsh
# Compile Tézeu et fabrique build/Tezeu.app, signée avec le certificat local « Tezeu Dev ».
set -euo pipefail
cd "$(dirname "$0")"

./scripts/fetch-whisper.sh
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Tezeu"

APP=build/Tezeu.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Tezeu"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Frameworks"
ditto Vendor/whisper.xcframework/macos-arm64_x86_64/whisper.framework "$APP/Contents/Frameworks/whisper.framework"

# Même certificat à chaque compilation = macOS garde les autorisations.
codesign --force --sign "Tezeu Dev" "$APP/Contents/Frameworks/whisper.framework"
codesign --force --sign "Tezeu Dev" "$APP"
echo "OK : $APP"
