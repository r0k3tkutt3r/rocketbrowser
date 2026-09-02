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
# Hardened runtime: no library injection, no debugger attach without root — the
# barrier that keeps local malware out of the password vault's decrypted memory.
# The entitlements re-grant the device access hardened runtime would otherwise cut
# off. Only unrestricted ones belong there: a restricted entitlement on an ad-hoc
# signature gets the app SIGKILLed by AMFI at launch.
codesign --force --sign - --options runtime --entitlements Entitlements.plist "$APP"

# Nudge Finder/Dock to re-read the icon instead of serving a cached placeholder.
touch "$APP"

echo "Built $APP"

# ./build.sh --install  replaces /Applications/Rocket.app safely.
#
# Do NOT use `cp -R build/Rocket.app /Applications/` when a copy is already there:
# cp merges the new files over the old bundle in place, and macOS keeps the previous
# code signature cached for that path. The result passes `codesign --verify` on disk
# but the kernel kills it on launch with SIGKILL "Code Signature Invalid".
if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications/$APP_NAME.app"
    if pgrep -x "$APP_NAME" >/dev/null; then
        echo "note: $APP_NAME is running — quit it and relaunch to pick up this build"
    fi
    rm -rf "$DEST"                      # replace wholesale, never merge in place
    ditto "$APP" "$DEST"
    # Fresh signature, so no stale cache — same hardening as the build above.
    codesign --force --sign - --options runtime --entitlements Entitlements.plist "$DEST"
    touch "$DEST"
    echo "Installed $DEST"
    echo "Run with: open $DEST"
else
    echo "Run with: open $APP"
    echo "Install with: ./build.sh --install"
fi
