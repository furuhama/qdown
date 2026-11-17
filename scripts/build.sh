#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/Release/Qdown.app"
DERIVED="$ROOT/build/DerivedData"

echo "==> Building Qdown (arm64 + x86_64)"
xcodebuild \
  -project Qdown.xcodeproj \
  -scheme Qdown \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  build

if [ ! -d "$APP" ]; then
  echo "error: expected app was not produced at $APP" >&2
  exit 1
fi

echo
echo "==> App: $APP"
/usr/bin/lipo -info "$APP/Contents/MacOS/Qdown"
/usr/bin/file "$APP/Contents/MacOS/Qdown"
/usr/bin/codesign --verify --deep --strict "$APP" && echo "codesign: OK"
