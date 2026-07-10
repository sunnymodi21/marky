#!/usr/bin/env bash
# Packages the SPM-built Marky binary into Marky.app.
# Usage: ./Scripts/package_app.sh [debug|release] [notarize]
#
# "notarize" (or MARKY_NOTARIZE=1) additionally notarizes and staples the app and
# leaves a distributable zip in dist/. Requires a Developer ID Application identity
# plus notary credentials, resolved in this order:
#   1. MARKY_NOTARY_PROFILE (a notarytool keychain profile name)
#   2. APPLE_ID + APPLE_TEAM_ID + APPLE_APP_SPECIFIC_PASSWORD, from the environment
#      or the gitignored .env at the repo root
#   3. keychain profile "marky-notary"
#      (create via: xcrun notarytool store-credentials marky-notary ...)
set -euo pipefail

CONFIG="${1:-release}"
NOTARIZE=0
if [ "${2:-}" = "notarize" ] || [ "${MARKY_NOTARIZE:-0}" = "1" ]; then
    NOTARIZE=1
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Marky.app"

cd "$ROOT"
swift build -c "$CONFIG"

BUILD_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/Marky" "$APP/Contents/MacOS/Marky"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

ICON_SOURCE="$ROOT/Assets/AppIconSource.png"
if [ -f "$ICON_SOURCE" ]; then
    ICONSET_DIR="$(mktemp -d)/Marky.iconset"
    mkdir -p "$ICONSET_DIR"

    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
        sips -z "$((size * 2))" "$((size * 2))" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
    done

    iconutil -c icns "$ICONSET_DIR" -o "$APP/Contents/Resources/Marky.icns"
    rm -rf "$(dirname "$ICONSET_DIR")"
fi

# Copy SPM resource bundles (e.g. KeyboardShortcuts localizations).
find "$BUILD_DIR" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;

# Sign with a STABLE identity so TCC (Accessibility) grants persist across rebuilds.
# Ad-hoc signing keys the identity off the binary hash, which changes every build —
# macOS then treats each rebuild as a new/modified app and revokes the grant. A real
# signing identity (Developer ID / Apple Development) yields a stable designated
# requirement (team + bundle id), so the grant sticks.
#
# Override with MARKY_SIGN_ID="<identity name or hash>"; otherwise auto-detect, and
# fall back to ad-hoc only when no identity is available.
SIGN_ID="${MARKY_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')"
    [ -z "$SIGN_ID" ] && SIGN_ID="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')"
fi

CODESIGN_ARGS=(--force --deep)
if [ "$NOTARIZE" = "1" ]; then
    # Notarization requires the hardened runtime and a secure timestamp.
    CODESIGN_ARGS+=(--options runtime --timestamp)
elif [ "${MARKY_HARDENED_RUNTIME:-0}" = "1" ]; then
    CODESIGN_ARGS+=(--options runtime)
fi

if [ -n "$SIGN_ID" ]; then
    codesign "${CODESIGN_ARGS[@]}" --sign "$SIGN_ID" "$APP"
    echo "Signed with: $SIGN_ID"
else
    codesign "${CODESIGN_ARGS[@]}" --sign - "$APP"
    echo "Signed ad-hoc (no stable identity found; Accessibility grant won't persist across rebuilds)"
fi

echo "Packaged: $APP ($CONFIG)"

if [ "$NOTARIZE" = "1" ]; then
    # Notarization only accepts Developer ID signatures — check what actually
    # landed on the app rather than trusting how SIGN_ID was spelled.
    SIGN_INFO="$(codesign -dvv "$APP" 2>&1)"
    if ! grep -q 'Authority=Developer ID Application' <<< "$SIGN_INFO"; then
        echo "error: notarization requires a 'Developer ID Application' signature." >&2
        echo "       Set MARKY_SIGN_ID to your Developer ID identity and re-run." >&2
        exit 1
    fi

    # Notary credentials can live in a gitignored .env (APPLE_ID, APPLE_TEAM_ID,
    # APPLE_APP_SPECIFIC_PASSWORD) — loaded only for the notarize step.
    if [ -f "$ROOT/.env" ]; then
        set -a
        # shellcheck disable=SC1091
        . "$ROOT/.env"
        set +a
    fi

    APP_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-${APPLE_APP_PASSWORD:-}}"
    NOTARY_ARGS=()
    if [ -n "${MARKY_NOTARY_PROFILE:-}" ]; then
        NOTARY_ARGS=(--keychain-profile "$MARKY_NOTARY_PROFILE")
    elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "$APP_PASSWORD" ]; then
        NOTARY_ARGS=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APP_PASSWORD")
    else
        NOTARY_ARGS=(--keychain-profile marky-notary)
    fi

    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo dev)"
    DIST="$ROOT/dist"
    ZIP="$DIST/Marky-$VERSION.zip"
    mkdir -p "$DIST"

    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"

    echo "Submitting to Apple notary service (this can take a few minutes)..."
    xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait

    xcrun stapler staple "$APP"

    # Re-zip so the distributed archive contains the stapled app.
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"

    echo "Notarized and stapled: $APP"
    echo "Distributable: $ZIP"
fi
