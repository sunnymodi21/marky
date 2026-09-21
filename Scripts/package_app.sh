#!/usr/bin/env bash
# Packages the SPM-built Marky binary into Marky.app.
# Usage: ./Scripts/package_app.sh [debug|release] [notarize]
#        ./Scripts/package_app.sh mas [upload]
#
# "mas" builds a sandboxed Mac App Store package (no Sparkle) at dist/Marky.pkg.
# "upload" (or MARKY_MAS_UPLOAD=1) sends that pkg to App Store Connect via Transporter.
# MAS upload requires APPSTORE_API_KEY and APPSTORE_ISSUER_ID from the environment
# or the gitignored .env (no hardcoded defaults).
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
shopt -s nullglob

CONFIG="${1:-release}"
MAS=0
UPLOAD=0
NOTARIZE=0
if [ "${1:-}" = "mas" ]; then
    MAS=1
    CONFIG="release"
    if [ "${2:-}" = "upload" ] || [ "${MARKY_MAS_UPLOAD:-0}" = "1" ]; then
        UPLOAD=1
    fi
elif [ "${2:-}" = "notarize" ] || [ "${MARKY_NOTARIZE:-0}" = "1" ]; then
    NOTARIZE=1
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Marky.app"
PLIST="$APP/Contents/Info.plist"
DIST="$ROOT/dist"

# Name of the first valid identity whose description matches the pattern.
# Extra args (e.g. -p codesigning) are passed through to security.
find_identity() {
    security find-identity -v "${@:2}" | awk -F'"' -v pat="$1" '$0 ~ pat {print $2; exit}'
}

# Credentials (Apple ID / App Store Connect) may live in a gitignored .env.
load_env() {
    if [ -f "$ROOT/.env" ]; then
        set -a
        # shellcheck disable=SC1091
        . "$ROOT/.env"
        set +a
    fi
}

cd "$ROOT"
BUILD_ARGS=(-c "$CONFIG")
if [ "$MAS" = "1" ]; then
    export MARKY_APP_STORE=1
    BUILD_ARGS+=(-Xswiftc -DAPPSTORE)
fi
swift build "${BUILD_ARGS[@]}"

BUILD_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

# SwiftPM generates dependency resource accessors for command-line executables
# using Bundle.main.bundleURL. Once the executable is wrapped in a macOS .app,
# that points at Marky.app/, while valid app resources live in
# Marky.app/Contents/Resources/. Patch the generated accessor and rebuild so a
# clean install does not fall back to this development machine's .build path.
RESOURCE_ACCESSOR="$BUILD_DIR/KeyboardShortcuts.build/DerivedSources/resource_bundle_accessor.swift"
ACCESSOR_OLD='Bundle.main.bundleURL.appendingPathComponent'
ACCESSOR_NEW='(Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent'
if grep -Fqs "$ACCESSOR_OLD" "$RESOURCE_ACCESSOR"; then
    python3 -c 'import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace(sys.argv[2], sys.argv[3]))' \
        "$RESOURCE_ACCESSOR" "$ACCESSOR_OLD" "$ACCESSOR_NEW"
    swift build "${BUILD_ARGS[@]}"
fi
if ! grep -Fqs "$ACCESSOR_NEW" "$RESOURCE_ACCESSOR"; then
    echo "error: KeyboardShortcuts resource accessor missing or not patched: $RESOURCE_ACCESSOR" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/Marky" "$APP/Contents/MacOS/Marky"
cp "$ROOT/Info.plist" "$PLIST"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -f "$ROOT/PrivacyInfo.xcprivacy" ]; then
    cp "$ROOT/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
fi
if [ -f "$ROOT/Sources/Marky/SmartFill/gliner_worker.py" ]; then
    cp "$ROOT/Sources/Marky/SmartFill/gliner_worker.py" "$APP/Contents/Resources/gliner_worker.py"
fi
if [ "$MAS" != "1" ] && [ "$CONFIG" = "release" ]; then
    "$ROOT/Scripts/prepare_python_runtime.sh"
    ditto "$ROOT/.build/marky-python-runtime" "$APP/Contents/Resources/python"
fi

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

# App Store validation requires every bundled .bundle to have CFBundleIdentifier.
for bundle in "$APP/Contents/Resources/"*.bundle; do
    bplist="$bundle/Contents/Info.plist"
    [ -f "$bplist" ] || bplist="$bundle/Info.plist"
    [ -f "$bplist" ] || continue
    if ! /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bplist" >/dev/null 2>&1; then
        name="$(basename "$bundle" .bundle | tr '_' '-' | tr -c 'A-Za-z0-9.-' '-' | sed -E 's/-+$//; s/^-+//')"
        /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.sunnymodi.marky.$name" "$bplist"
        /usr/libexec/PlistBuddy -c "Add :CFBundleName string $name" "$bplist" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string BNDL" "$bplist" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "$bplist" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 1.0" "$bplist" 2>/dev/null || true
    fi
done

if [ "$MAS" = "1" ]; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.1' "$PLIST"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 7' "$PLIST"
    for key in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks ITSAppUsesNonExemptEncryption; do
        /usr/libexec/PlistBuddy -c "Delete :$key" "$PLIST" 2>/dev/null || true
    done
    /usr/libexec/PlistBuddy -c 'Add :ITSAppUsesNonExemptEncryption bool false' "$PLIST"
    cp "$ROOT/Signing/Marky_Mac_App_Store.provisionprofile" "$APP/Contents/embedded.provisionprofile"
    # SwiftPM dependency resources may be read-only; make the staged copy writable
    # so xattr can remove provenance metadata before App Store signing.
    chmod -R u+w "$APP"
    xattr -cr "$APP"
else
    # Embed Sparkle.framework (XPC helpers + Autoupdate live inside it). SPM links
    # Sparkle but does not copy the framework into the app bundle.
    SPARKLE_FW=""
    for candidate in "$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework"/macos-*/Sparkle.framework; do
        SPARKLE_FW="$candidate"
        break
    done
    if [ ! -d "$SPARKLE_FW" ]; then
        echo "error: Sparkle.framework not found under .build/artifacts/sparkle" >&2
        echo "       Run: swift package resolve" >&2
        exit 1
    fi
    mkdir -p "$APP/Contents/Frameworks"
    ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
fi

# swift build records an rpath into .build/; the packaged app must look next
# to itself. Strip the ad-hoc signature first — install_name_tool refuses to
# rewrite a signed binary.
codesign --remove-signature "$APP/Contents/MacOS/Marky" 2>/dev/null || true
if [ "$MAS" != "1" ] && ! otool -l "$APP/Contents/MacOS/Marky" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Marky"
fi

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
    if [ "$MAS" = "1" ]; then
        SIGN_ID="$(find_identity '3rd Party Mac Developer Application' -p codesigning)"
    else
        SIGN_ID="$(find_identity 'Developer ID Application' -p codesigning)"
        [ -z "$SIGN_ID" ] && SIGN_ID="$(find_identity 'Apple Development' -p codesigning)"
    fi
fi

# Sparkle forbids --deep on the outer app: it can strip XPC entitlements.
# Sign nested Sparkle helpers inside-out, then the app bundle without --deep.
CODESIGN_NESTED=(--force --preserve-metadata=entitlements,requirements,flags,runtime)
CODESIGN_BUNDLE=(--force)
CODESIGN_APP=(--force)
if [ "$MAS" = "1" ]; then
    CODESIGN_BUNDLE+=(--options runtime --timestamp)
    CODESIGN_APP+=(--options runtime --timestamp --entitlements "$ROOT/Signing/Marky.entitlements")
elif [ "$NOTARIZE" = "1" ]; then
    # Notarization requires the hardened runtime and a secure timestamp.
    CODESIGN_NESTED+=(--options runtime --timestamp)
    CODESIGN_BUNDLE+=(--options runtime --timestamp)
    CODESIGN_APP+=(--options runtime --timestamp)
elif [ "${MARKY_HARDENED_RUNTIME:-0}" = "1" ]; then
    CODESIGN_NESTED+=(--options runtime)
    CODESIGN_APP+=(--options runtime)
fi

if [ -n "$SIGN_ID" ]; then
    SIGN_ARGS=(--sign "$SIGN_ID")
    SIGN_LABEL="$SIGN_ID"
else
    if [ "$MAS" = "1" ]; then
        echo "error: Mac App Store packaging requires a '3rd Party Mac Developer Application' identity." >&2
        exit 1
    fi
    SIGN_ARGS=(--sign -)
    SIGN_LABEL="ad-hoc (no stable identity found; Accessibility grant won't persist across rebuilds)"
fi

if [ "$MAS" != "1" ]; then
    SPARKLE_VER="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
    for helper in XPCServices/Installer.xpc XPCServices/Downloader.xpc Updater.app Autoupdate; do
        codesign "${CODESIGN_NESTED[@]}" "${SIGN_ARGS[@]}" "$SPARKLE_VER/$helper"
    done
    codesign "${CODESIGN_NESTED[@]}" "${SIGN_ARGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
fi

# Sign SPM resource bundles inside-out (no --deep). KeyboardShortcuts.Recorder
# loads Bundle.module; an unsigned .bundle makes Bundle(url:) return nil under
# the MAS hardened runtime and the accessor fatalErrors.
for bundle in "$APP/Contents/Resources/"*.bundle; do
    codesign "${CODESIGN_BUNDLE[@]}" "${SIGN_ARGS[@]}" "$bundle"
done

# The bundled inference runtime contains Python, extension modules, and PyTorch
# libraries. Sign every Mach-O file with Marky's identity before the outer app.
if [ -d "$APP/Contents/Resources/python" ]; then
    while IFS= read -r binary; do
        codesign "${CODESIGN_NESTED[@]}" "${SIGN_ARGS[@]}" "$binary"
    done < <(find "$APP/Contents/Resources/python" -type f -print0 \
        | xargs -0 file \
        | awk -F: '/Mach-O/ && $1 !~ / \(for architecture/ {print $1}')
fi

codesign "${CODESIGN_APP[@]}" "${SIGN_ARGS[@]}" "$APP"
echo "Signed with: $SIGN_LABEL"

echo "Packaged: $APP ($CONFIG)"

if [ "$MAS" = "1" ]; then
    INSTALLER_ID="${MARKY_INSTALLER_ID:-$(find_identity '3rd Party Mac Developer Installer')}"
    if [ -z "$INSTALLER_ID" ]; then
        echo "error: Mac App Store packaging requires a '3rd Party Mac Developer Installer' identity." >&2
        exit 1
    fi

    PKG="$DIST/Marky.pkg"
    mkdir -p "$DIST"
    rm -f "$PKG"
    productbuild --component "$APP" /Applications --sign "$INSTALLER_ID" "$PKG"
    echo "Installer: $PKG"
    echo "Signed with: $INSTALLER_ID"

    if [ "$UPLOAD" = "1" ]; then
        load_env
        TRANSPORTER="/Applications/Transporter.app/Contents/itms/bin/iTMSTransporter"
        if [ ! -x "$TRANSPORTER" ]; then
            echo "error: Transporter.app is required to upload to App Store Connect." >&2
            exit 1
        fi
        echo "Uploading $PKG to App Store Connect..."
        "$TRANSPORTER" -m upload -assetFile "$PKG" \
            -apiKey "${APPSTORE_API_KEY:?set APPSTORE_API_KEY}" \
            -apiIssuer "${APPSTORE_ISSUER_ID:?set APPSTORE_ISSUER_ID}"
    fi
fi

if [ "$NOTARIZE" = "1" ]; then
    # Notarization only accepts Developer ID signatures — check what actually
    # landed on the app rather than trusting how SIGN_ID was spelled.
    SIGN_INFO="$(codesign -dvv "$APP" 2>&1)"
    if ! grep -q 'Authority=Developer ID Application' <<< "$SIGN_INFO"; then
        echo "error: notarization requires a 'Developer ID Application' signature." >&2
        echo "       Set MARKY_SIGN_ID to your Developer ID identity and re-run." >&2
        exit 1
    fi

    load_env
    APP_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-${APPLE_APP_PASSWORD:-}}"
    if [ -n "${MARKY_NOTARY_PROFILE:-}" ]; then
        NOTARY_ARGS=(--keychain-profile "$MARKY_NOTARY_PROFILE")
    elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "$APP_PASSWORD" ]; then
        NOTARY_ARGS=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APP_PASSWORD")
    else
        NOTARY_ARGS=(--keychain-profile marky-notary)
    fi

    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || echo dev)"
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
    echo "Then: ./Scripts/generate_appcast.sh  # upload dist/updates/ to download.marky.click"
fi
