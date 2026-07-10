#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT_DIR/Assets/AppIcon.svg"
PNG="$ROOT_DIR/Assets/AppIcon.png"
ICNS="$ROOT_DIR/Assets/AppIcon.icns"

command -v rsvg-convert >/dev/null 2>&1 || {
  echo "rsvg-convert is required (brew install librsvg)" >&2
  exit 1
}

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/limits-icon.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
iconset="$work_dir/AppIcon.iconset"
mkdir -p "$iconset"

rsvg-convert --width 1024 --height 1024 --keep-aspect-ratio "$SOURCE" --output "$PNG"
for size in 16 32 128 256 512; do
  rsvg-convert --width "$size" --height "$size" --keep-aspect-ratio "$SOURCE" --output "$iconset/icon_${size}x${size}.png"
  double=$((size * 2))
  rsvg-convert --width "$double" --height "$double" --keep-aspect-ratio "$SOURCE" --output "$iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$iconset" -o "$ICNS"

echo "$PNG"
echo "$ICNS"
