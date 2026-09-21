#!/usr/bin/env bash
# Builds the relocatable Python + GLiNER runtime embedded in direct release builds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$ROOT/.build/marky-python-runtime"
RUNTIME_VERSION="python-3.12.14-20260901-gliner2-2.0.0-torch-2.14.0"
MARKER="$RUNTIME/.marky-runtime-version"
ARCHIVE_URL="https://github.com/astral-sh/python-build-standalone/releases/download/20260901/cpython-3.12.14%2B20260901-aarch64-apple-darwin-install_only_stripped.tar.gz"
ARCHIVE_SHA256="81a359f1cfadd4da11766534c5913791cea55f26e1bb902cacd2a531bb1e4b2b"

prune_runtime() {
    local runtime="$1"
    local site_packages="$runtime/lib/python3.12/site-packages"

    # Wheels include developer-only headers and test suites that inference
    # never imports. Keep package metadata because libraries use it for
    # runtime version and feature checks.
    find "$runtime" -type d -name __pycache__ -prune -exec rm -rf {} +
    rm -rf "$runtime/include" "$runtime/share"
    find "$site_packages" -type d \
        \( -name include -o -name test -o -name tests \) \
        -prune -exec rm -rf {} +
    rm -rf "$site_packages/pip" "$site_packages"/pip-*.dist-info
    rm -rf "$site_packages/setuptools" "$site_packages"/setuptools-*.dist-info
    rm -f "$runtime/bin/pip" "$runtime/bin/pip3" "$runtime/bin/pip3.12"
}

if [ -f "$MARKER" ] && [ "$(<"$MARKER")" = "$RUNTIME_VERSION" ]; then
    prune_runtime "$RUNTIME"
    echo "Bundled Python runtime is ready: $RUNTIME"
    exit 0
fi

STAGING="$(mktemp -d)"
cleanup() {
    rm -rf "$STAGING"
}
trap cleanup EXIT

ARCHIVE="$STAGING/python.tar.gz"
echo "Downloading relocatable Python 3.12..."
curl -fL --retry 3 -o "$ARCHIVE" "$ARCHIVE_URL"
ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$ARCHIVE_SHA256" ]; then
    echo "error: bundled Python archive failed verification" >&2
    exit 1
fi

tar -xzf "$ARCHIVE" -C "$STAGING"
PYTHON="$STAGING/python/bin/python3"
echo "Installing pinned Smart Fill dependencies..."
"$PYTHON" -m pip install --no-cache-dir \
    'gliner2[local]==2.0.0' \
    'torch==2.14.0' \
    'transformers==4.51.3' \
    'protobuf==7.36.2'

# Build tools, headers, tests, and bytecode caches are unnecessary at runtime.
# Keeping source files preserves useful tracebacks.
prune_runtime "$STAGING/python"

printf '%s\n' "$RUNTIME_VERSION" > "$STAGING/python/.marky-runtime-version"
rm -rf "$RUNTIME"
mv "$STAGING/python" "$RUNTIME"
echo "Bundled Python runtime is ready: $RUNTIME"
