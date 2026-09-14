#!/bin/bash
#
# install_icon.sh — install one of the Cairn icon concepts into the asset catalog.
#
# Usage:   ./install_icon.sh 02-cairn-mark.png
#
# Generates every required iOS/macOS size with sips and writes a valid
# AppIcon.appiconset/Contents.json. Run from anywhere; paths are resolved
# relative to this script. This is the only step that touches the Xcode project.
#
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <concept.png>   (e.g. 02-cairn-mark.png)" >&2
    exit 64
fi

SRC="$(cd "$(dirname "$0")" && pwd)/$1"
DEST="$(cd "$(dirname "$0")/../../CairnApp/Resources/Assets.xcassets/AppIcon.appiconset" 2>/dev/null && pwd)"

if [[ ! -f "$SRC" ]]; then
    echo "error: source not found: $SRC" >&2
    exit 66
fi
if [[ -z "${DEST:-}" || ! -d "$DEST" ]]; then
    echo "error: AppIcon.appiconset not found next to $SRC" >&2
    exit 66
fi

# Guard: must be a 1024x1024 opaque PNG.
read -r W H < <(sips -g pixelWidth -g pixelHeight "$SRC" | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w, h}')
if [[ "$W" != "1024" || "$H" != "1024" ]]; then
    echo "error: master must be 1024x1024 (got ${W}x${H})" >&2
    exit 65
fi

echo "Installing $(basename "$SRC") into AppIcon.appiconset …"

cp "$SRC" "$DEST/AppIcon-1024.png"

sips -z 16  16  "$SRC" --out "$DEST/icon_16x16.png"      >/dev/null
sips -z 32  32  "$SRC" --out "$DEST/icon_16x16@2x.png"   >/dev/null
sips -z 32  32  "$SRC" --out "$DEST/icon_32x32.png"      >/dev/null
sips -z 64  64  "$SRC" --out "$DEST/icon_32x32@2x.png"   >/dev/null
sips -z 128 128 "$SRC" --out "$DEST/icon_128x128.png"    >/dev/null
sips -z 256 256 "$SRC" --out "$DEST/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$SRC" --out "$DEST/icon_256x256.png"    >/dev/null
sips -z 512 512 "$SRC" --out "$DEST/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$SRC" --out "$DEST/icon_512x512.png"    >/dev/null
cp "$SRC" "$DEST/icon_512x512@2x.png"

cat > "$DEST/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "AppIcon-1024.png",     "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "filename" : "icon_16x16.png",       "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png",    "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png",       "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png",    "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png",     "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",     "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",     "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "Done. Build the Cairn scheme to verify."
