#!/usr/bin/env bash
# Build a Sparkle appcast from notarized archives in dist/.
#
# Usage: ./Scripts/generate_appcast.sh
#
# Bump CFBundleVersion in Info.plist before packaging a new update — Sparkle
# compares that integer, not CFBundleShortVersionString.
#
# Looks for versioned archives (dist/Marky-*.dmg and dist/Marky-*.zip),
# copies them into dist/updates/, and writes dist/updates/appcast.xml.
# Upload that directory to https://download.marky.click/ (keep Marky.dmg as the
# landing-page alias for the latest build).
#
# Signing key: uses sparkle_eddsa.key in the repo root if present (gitignored),
# otherwise the "Private key for signing Sparkle updates" item in the login
# Keychain (created by generate_keys).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
UPDATES="$DIST/updates"
PREFIX="${MARKY_UPDATE_URL_PREFIX:-https://download.marky.click/}"
SITE="${MARKY_SITE_URL:-https://marky.click}"
KEY_FILE="$ROOT/sparkle_eddsa.key"

cd "$ROOT"

SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
if [ ! -x "$SPARKLE_BIN/generate_appcast" ]; then
    swift package resolve
fi
if [ ! -x "$SPARKLE_BIN/generate_appcast" ]; then
    echo "error: Sparkle generate_appcast not found under .build/artifacts/sparkle" >&2
    exit 1
fi

mkdir -p "$UPDATES"

shopt -s nullglob
archives=("$DIST"/Marky-*.dmg)
for archive in "$DIST"/Marky-*.zip; do
    # Sparkle rejects duplicate formats of the same release. Keep the DMG for
    # that release, but include ZIPs for every release without a matching DMG.
    if [ ! -f "${archive%.zip}.dmg" ]; then
        archives+=("$archive")
    fi
done
shopt -u nullglob

if [ ${#archives[@]} -eq 0 ]; then
    echo "error: no dist/Marky-*.dmg or dist/Marky-*.zip found." >&2
    echo "       Package a release first (Scripts/create_dmg.sh or package_app.sh release notarize)." >&2
    exit 1
fi

for archive in "${archives[@]}"; do
    cp "$archive" "$UPDATES/"
done

GEN_ARGS=(
    --download-url-prefix "$PREFIX"
    --link "$SITE"
    -o "$UPDATES/appcast.xml"
)
if [ -f "$KEY_FILE" ]; then
    GEN_ARGS+=(--ed-key-file "$KEY_FILE")
fi

"$SPARKLE_BIN/generate_appcast" "${GEN_ARGS[@]}" "$UPDATES"

# generate_appcast skips EdDSA if the archive's app has no SUPublicEDKey
# (older builds). The running Sparkle client still requires a signature.
if ! grep -q 'sparkle:edSignature=' "$UPDATES/appcast.xml"; then
    SIGN_ARGS=()
    if [ -f "$KEY_FILE" ]; then
        SIGN_ARGS+=(--ed-key-file "$KEY_FILE")
    fi
    shopt -s nullglob
    for archive in "$UPDATES"/*.dmg "$UPDATES"/*.zip; do
        SIG="$("$SPARKLE_BIN/sign_update" "${SIGN_ARGS[@]}" -p "$archive")"
        NAME="$(basename "$archive")"
        python3 -c "
from pathlib import Path
import re
path = Path('$UPDATES/appcast.xml')
sig = '''$SIG'''.strip()
name = '''$NAME'''
xml = path.read_text()
pat = re.compile(r'(<enclosure[^>]*url=\"[^\"]*' + re.escape(name) + r'\"[^>]*)(/>)')
def repl(m):
    tag = m.group(1)
    if 'sparkle:edSignature=' in tag:
        return m.group(0)
    return tag.rstrip() + f' sparkle:edSignature=\"{sig}\"' + m.group(2)
new, n = pat.subn(repl, xml, count=1)
if n:
    path.write_text(new)
"
    done
    shopt -u nullglob
fi

echo "Appcast: $UPDATES/appcast.xml"
echo "Upload the contents of $UPDATES to $PREFIX"
echo "Keep https://download.marky.click/Marky.dmg as a copy of the latest archive for the landing page."
