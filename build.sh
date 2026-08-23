#!/bin/zsh
# Builds Rocket.app with swiftc — no Xcode project needed (Command Line Tools suffice).
set -euo pipefail
cd "${0:a:h}"

APP_NAME="Rocket"
APP="build/$APP_NAME.app"
ARCH="$(uname -m)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

xcrun -sdk macosx swiftc \
    -O -swift-version 5 \
    -target "$ARCH-apple-macos14.0" \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/$APP_NAME"

cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run with: open $APP"
