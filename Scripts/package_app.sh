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

# Copy SPM resource bundles (e.g. KeyboardShortcuts localizations).
find "$BUILD_DIR" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;

# Ad-hoc sign so TCC (Accessibility) permissions stick across rebuilds.
codesign --force --deep --sign - "$APP"

echo "Packaged: $APP ($CONFIG)"
