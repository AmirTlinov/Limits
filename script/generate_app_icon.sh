#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT_DIR/Assets/AppIcon.png"
ICNS="$ROOT_DIR/Assets/AppIcon.icns"

[[ -f "$SOURCE" ]] || { echo "Missing icon source: $SOURCE" >&2; exit 1; }
command -v sips >/dev/null 2>&1 || { echo "sips is required" >&2; exit 1; }
command -v iconutil >/dev/null 2>&1 || { echo "iconutil is required" >&2; exit 1; }

property() {
  sips -g "$1" "$SOURCE" 2>/dev/null | awk -F ': ' -v key="$1" '$1 ~ key { print $2 }'
}

[[ "$(property pixelWidth)" == "1024" && "$(property pixelHeight)" == "1024" ]] || {
  echo "AppIcon.png must be exactly 1024x1024" >&2
  exit 1
}
[[ "$(property hasAlpha)" == "yes" ]] || {
  echo "AppIcon.png must preserve transparent outer corners" >&2
  exit 1
}

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/limits-icon.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
iconset="$work_dir/AppIcon.iconset"
mkdir -p "$iconset"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SOURCE" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$SOURCE" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset" -o "$ICNS"
[[ -s "$ICNS" ]] || { echo "iconutil did not produce $ICNS" >&2; exit 1; }

echo "$SOURCE"
echo "$ICNS"
