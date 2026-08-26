#!/usr/bin/env bash
# Build, sign, notarize, and package Marky into a distributable DMG.
# Requires .env with APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, and APPLE_TEAM_ID.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Marky.app"
DIST="$ROOT/dist"
STAGING=""

cleanup() {
  if [[ -n "$STAGING" && -d "$STAGING" ]]; then
    rm -rf "$STAGING"
  fi
}
trap cleanup EXIT

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

for var in APPLE_ID APPLE_APP_SPECIFIC_PASSWORD APPLE_TEAM_ID; do
  if [[ -z "${!var:-}" ]]; then
    echo "Missing $var (set in .env)" >&2
    exit 1
  fi
done

MARKY_SIGN_ID="${MARKY_SIGN_ID:-${SIGNING_IDENTITY:-$(security find-identity -v -p codesigning \
  | awk -v team="$APPLE_TEAM_ID" -F'"' '/Developer ID Application/ && $2 ~ team { print $2; exit }')}}"

if [[ -z "$MARKY_SIGN_ID" ]]; then
  echo "No Developer ID Application identity found for team $APPLE_TEAM_ID" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Info.plist")"
DMG="$DIST/Marky-${VERSION}.dmg"

echo "Packaging with: $MARKY_SIGN_ID"
MARKY_SIGN_ID="$MARKY_SIGN_ID" MARKY_HARDENED_RUNTIME=1 "$ROOT/Scripts/package_app.sh" release
codesign --verify --deep --strict --verbose=2 "$APP"

mkdir -p "$DIST"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create \
  -volname "Marky" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG" >/dev/null

echo "Notarizing $DMG (this may take a few minutes)..."
xcrun notarytool submit "$DMG" \
  --apple-id "$APPLE_ID" \
  --password "$APPLE_APP_SPECIFIC_PASSWORD" \
  --team-id "$APPLE_TEAM_ID" \
  --wait

xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "Release DMG ready: $DMG"
echo "Sparkle: bump CFBundleVersion, then ./Scripts/generate_appcast.sh and upload dist/updates/ to download.marky.click"
