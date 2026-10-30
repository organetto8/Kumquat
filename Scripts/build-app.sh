#!/usr/bin/env bash
# Builds build/Kumquat.app from the Swift package.
#
#   ARCHS="arm64 x86_64"   universal binary (default: this Mac's architecture)
#   SIGN_IDENTITY="Developer ID Application: …"   (default: first "Apple Development"
#                  identity in the keychain, else ad-hoc "-"; a real identity keeps
#                  privacy permissions such as Input Monitoring across rebuilds)
#   EXIFTOOL_DIR=/path/to/Image-ExifTool   bundle ExifTool into Resources/ExifTool
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(cat VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
ARCHS="${ARCHS:-$(uname -m)}"
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
    SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
APP="build/Kumquat.app"

arch_flags=()
for arch in $ARCHS; do arch_flags+=(--arch "$arch"); done

swift build -c release "${arch_flags[@]}"
bin_dir="$(swift build -c release "${arch_flags[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$bin_dir/Kumquat" "$APP/Contents/MacOS/Kumquat"
strip -x "$APP/Contents/MacOS/Kumquat"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for catalog in Resources/*.xcstrings; do
    xcrun xcstringstool compile "$catalog" --output-directory "$APP/Contents/Resources"
done

if [[ -n "${EXIFTOOL_DIR:-}" ]]; then
    mkdir -p "$APP/Contents/Resources/ExifTool"
    cp -R "$EXIFTOOL_DIR/exiftool" "$EXIFTOOL_DIR/lib" "$APP/Contents/Resources/ExifTool/"
    cp "$EXIFTOOL_DIR/LICENSE" "$APP/Contents/Resources/ExifTool/" 2>/dev/null || true
fi

sign_flags=(--force --options runtime --entitlements Resources/Kumquat.entitlements --sign "$SIGN_IDENTITY")
[[ "$SIGN_IDENTITY" == Developer\ ID* ]] && sign_flags+=(--timestamp)
codesign "${sign_flags[@]}" "$APP"

echo "Built $APP ($VERSION build $BUILD_NUMBER, $ARCHS, signed: $SIGN_IDENTITY)"
