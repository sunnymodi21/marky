#!/usr/bin/env bash
# Packages the SPM-built Marky binary into Marky.app.
# Usage: ./Scripts/package_app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
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
if [ "${MARKY_HARDENED_RUNTIME:-0}" = "1" ]; then
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
