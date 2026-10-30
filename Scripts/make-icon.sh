#!/usr/bin/env bash
# Regenerates Resources/AppIcon.icns from Scripts/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"

swift Scripts/make-icon.swift "$work/icon-1024.png" >/dev/null
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$work/icon-1024.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$work/icon-1024.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o Resources/AppIcon.icns
cp "$work/icon-1024.png" docs/icon.png
echo "Wrote Resources/AppIcon.icns"
