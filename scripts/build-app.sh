#!/bin/bash
# Builds build/SpaceVoice.app (universal, signed).
#   VERSION=1.2.0 scripts/build-app.sh
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
# Without SIGN_IDENTITY it signs with the first Apple Development identity, or ad hoc.
# A stable identity matters: macOS ties the Accessibility permission to the signature.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/SpaceVoice.app"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/SpaceVoice"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SpaceVoice"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/ru.lproj "$APP/Contents/Resources/"

if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
echo "Signing with: $SIGN_IDENTITY"
codesign --force --options runtime --timestamp=none \
  --entitlements Resources/SpaceVoice.entitlements \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION, build $BUILD)"
