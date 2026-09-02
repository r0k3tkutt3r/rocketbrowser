#!/bin/zsh
# Builds Rocket.app with swiftc — no Xcode project needed (Command Line Tools suffice).
set -euo pipefail
cd "${0:a:h}"

APP_NAME="Rocket"
APP="build/$APP_NAME.app"
ARCH="$(uname -m)"

# ./build.sh [--universal] [--install | --notarize]
UNIVERSAL=0
ACTION=""
for arg in "$@"; do
    case "$arg" in
        --universal)          UNIVERSAL=1 ;;
        --install|--notarize) ACTION="$arg" ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# A plain build targets this Mac only, which keeps it a few seconds. Anything you hand
# to someone else wants --universal: a native arm64 binary simply will not launch on an
# Intel Mac, and the failure gives the user nothing to go on.
if [[ "$UNIVERSAL" == "1" ]]; then
    SLICES="$(mktemp -d)"
    trap 'rm -rf "$SLICES"' EXIT
    for slice_arch in arm64 x86_64; do
        xcrun -sdk macosx swiftc \
            -O -swift-version 5 \
            -target "$slice_arch-apple-macos14.0" \
            Sources/*.swift \
            -o "$SLICES/$slice_arch"
    done
    lipo -create "$SLICES/arm64" "$SLICES/x86_64" -output "$APP/Contents/MacOS/$APP_NAME"
else
    xcrun -sdk macosx swiftc \
        -O -swift-version 5 \
        -target "$ARCH-apple-macos14.0" \
        Sources/*.swift \
        -o "$APP/Contents/MacOS/$APP_NAME"
fi

# App icon: rendered from code (Tools/AppIcon.swift) into an .iconset, then packed
# into Rocket.icns. Finder, Launchpad and ⌘-Tab read this file from the bundle —
# a runtime NSApp.applicationIconImage only ever affects the live Dock tile.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING" "${SLICES:-}"' EXIT
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

# Signing identity. Prefer a Developer ID Application certificate for the team below;
# fall back to ad-hoc so the build still works on a machine without the certificate.
#
# The difference matters more than it looks. Hardened runtime only enforces LIBRARY
# VALIDATION — the rule that nothing but Apple-signed or same-team code may load into
# the process — when there is a real team behind the signature. Ad-hoc has no team, so
# the injection barrier the password vault leans on was never really there, and anyone
# could re-sign a modified copy ad-hoc and present it as Rocket. A Developer ID
# signature is what closes both.
#
# Override with:  ROCKET_SIGN_ID="<hash or identity name>" ./build.sh
TEAM_ID="HWWPT38672"
SIGN_ID="${ROCKET_SIGN_ID:-}"
if [[ -z "$SIGN_ID" ]]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -v team="$TEAM_ID" '/Developer ID Application/ && index($0, team) { print $2; exit }' || true)"
fi

sign_bundle() {
    local target="$1"
    if [[ -n "$SIGN_ID" ]]; then
        # --timestamp needs the network and is required for notarization.
        codesign --force --sign "$SIGN_ID" --options runtime --timestamp \
            --entitlements Entitlements.plist "$target"
    else
        codesign --force --sign - --options runtime --entitlements Entitlements.plist "$target"
    fi
}

if [[ -z "$SIGN_ID" ]]; then
    echo "warning: no Developer ID Application certificate for team $TEAM_ID in the keychain."
    echo "         Signing ad-hoc, which leaves library validation off — a modified copy"
    echo "         can be re-signed by anyone and still call itself Rocket."
fi
sign_bundle "$APP"

# Nudge Finder/Dock to re-read the icon instead of serving a cached placeholder.
touch "$APP"

echo "Built $APP"

# ./build.sh --install  replaces /Applications/Rocket.app safely.
#
# Do NOT use `cp -R build/Rocket.app /Applications/` when a copy is already there:
# cp merges the new files over the old bundle in place, and macOS keeps the previous
# code signature cached for that path. The result passes `codesign --verify` on disk
# but the kernel kills it on launch with SIGKILL "Code Signature Invalid".
if [[ "$ACTION" == "--install" ]]; then
    DEST="/Applications/$APP_NAME.app"
    if pgrep -x "$APP_NAME" >/dev/null; then
        echo "note: $APP_NAME is running — quit it and relaunch to pick up this build"
    fi
    rm -rf "$DEST"                      # replace wholesale, never merge in place
    ditto "$APP" "$DEST"
    # Fresh signature, so no stale cache — same hardening as the build above.
    sign_bundle "$DEST"
    touch "$DEST"
    echo "Installed $DEST"
    echo "Run with: open $DEST"
elif [[ "$ACTION" == "--notarize" ]]; then
    # Notarization proves to every other Mac that this build came from this team and
    # has not been altered since. It needs a Developer ID signature with a timestamp,
    # which is what sign_bundle produces above.
    #
    # One-time credential setup (stores an app-specific password in the keychain):
    #   xcrun notarytool store-credentials rocket-notary \
    #       --apple-id "<your Apple ID>" --team-id "$TEAM_ID" --password "<app-specific password>"
    # App-specific passwords come from appleid.apple.com, not your normal password.
    if [[ -z "$SIGN_ID" ]]; then
        echo "error: notarization needs a Developer ID signature; none was used." >&2
        exit 1
    fi
    if [[ "$UNIVERSAL" != "1" ]]; then
        echo "warning: this build is $ARCH only. Anyone on the other architecture cannot"
        echo "         run it. Use: ./build.sh --universal --notarize"
    fi
    ZIP="$(mktemp -d)/$APP_NAME.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "${ROCKET_NOTARY_PROFILE:-rocket-notary}" --wait
    # Stapling writes the ticket into the bundle so it validates without the network.
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
    echo "Notarized and stapled $APP"
else
    echo "Run with: open $APP"
    echo "Install with: ./build.sh --install"
    echo "For distribution: ./build.sh --universal && ./build.sh --universal --notarize"
fi
