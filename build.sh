#!/bin/zsh
# Builds Rocket.app with swiftc — no Xcode project needed (Command Line Tools suffice).
set -euo pipefail
cd "${0:a:h}"

APP_NAME="Rocket"
APP="build/$APP_NAME.app"
ARCH="$(uname -m)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun -sdk macosx swiftc \
    -O -swift-version 5 \
    -target "$ARCH-apple-macos14.0" \
    Sources/*.swift \
    -o "$APP/Contents/MacOS/$APP_NAME"

# App icon: rendered from code (Tools/AppIcon.swift) into an .iconset, then packed
# into Rocket.icns. Finder, Launchpad and ⌘-Tab read this file from the bundle —
# a runtime NSApp.applicationIconImage only ever affects the live Dock tile.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
xcrun -sdk macosx swiftc \
    -O -swift-version 5 \
    -target "$ARCH-apple-macos14.0" \
    Tools/*.swift \
    -o "$STAGING/makeicon"
"$STAGING/makeicon" "$STAGING/$APP_NAME.iconset" >/dev/null
iconutil --convert icns "$STAGING/$APP_NAME.iconset" \
    --output "$APP/Contents/Resources/$APP_NAME.icns"

cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP"

# Nudge Finder/Dock to re-read the icon instead of serving a cached placeholder.
touch "$APP"

echo "Built $APP"
echo "Run with: open $APP"
