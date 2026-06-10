#!/usr/bin/env bash
# Dev loop: kill running instance, build, test, package a debug app, relaunch.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

pkill -x Marky 2>/dev/null || true

swift build
swift test

"$ROOT/Scripts/package_app.sh" debug

open "$ROOT/Marky.app"
echo "Marky relaunched."
