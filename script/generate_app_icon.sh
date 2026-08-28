#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT_DIR/Assets/LimitsLogo.svg"
PNG="$ROOT_DIR/Assets/AppIcon.png"
ICNS="$ROOT_DIR/Assets/AppIcon.icns"
FAVICON="$ROOT_DIR/site/favicon.png"
SITE_LOGO="$ROOT_DIR/site/logo.svg"
MODE="generate"

if [[ "${1:-}" == "--check" ]]; then
  MODE="check"
  shift
fi
[[ $# -eq 0 ]] || { echo "Usage: $0 [--check]" >&2; exit 2; }

[[ -f "$SOURCE" ]] || { echo "Missing icon source: $SOURCE" >&2; exit 1; }
command -v sips >/dev/null 2>&1 || { echo "sips is required" >&2; exit 1; }
command -v iconutil >/dev/null 2>&1 || { echo "iconutil is required" >&2; exit 1; }
command -v xmllint >/dev/null 2>&1 || { echo "xmllint is required" >&2; exit 1; }
xmllint --noout "$SOURCE"
if grep -Eq '<image([[:space:]>])' "$SOURCE"; then
  echo "LimitsLogo.svg must contain vector geometry only" >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/limits-icon.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
generated_png="$work_dir/AppIcon.png"
generated_icns="$work_dir/AppIcon.icns"
generated_favicon="$work_dir/favicon.png"
generated_site_logo="$work_dir/logo.svg"
iconset="$work_dir/AppIcon.iconset"
mkdir -p "$iconset"

sips -s format png "$SOURCE" --out "$generated_png" >/dev/null

property() {
  sips -g "$1" "$generated_png" 2>/dev/null | awk -F ': ' -v key="$1" '$1 ~ key { print $2 }'
}

[[ "$(property pixelWidth)" == "1024" && "$(property pixelHeight)" == "1024" ]] || {
  echo "LimitsLogo.svg must render at exactly 1024x1024" >&2
  exit 1
}
[[ "$(property hasAlpha)" == "yes" ]] || {
  echo "LimitsLogo.svg must preserve transparent outer corners" >&2
  exit 1
}

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$generated_png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$generated_png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset" -o "$generated_icns"
sips -z 64 64 "$generated_png" --out "$generated_favicon" >/dev/null
install -m 0644 "$SOURCE" "$generated_site_logo"

[[ -s "$generated_icns" ]] || { echo "iconutil did not produce an app icon" >&2; exit 1; }

if [[ "$MODE" == "check" ]]; then
  for pair in \
    "$generated_png:$PNG" \
    "$generated_icns:$ICNS" \
    "$generated_favicon:$FAVICON" \
    "$generated_site_logo:$SITE_LOGO"; do
    generated="${pair%%:*}"
    tracked="${pair#*:}"
    if [[ ! -f "$tracked" ]] || ! cmp -s "$generated" "$tracked"; then
      echo "Generated logo asset is stale: $tracked" >&2
      echo "Run ./script/generate_app_icon.sh" >&2
      exit 1
    fi
  done
  echo "Logo assets match $SOURCE"
  exit 0
fi

install -m 0644 "$generated_png" "$PNG"
install -m 0644 "$generated_icns" "$ICNS"
install -m 0644 "$generated_favicon" "$FAVICON"
install -m 0644 "$generated_site_logo" "$SITE_LOGO"
echo "$SOURCE"
echo "$PNG"
echo "$ICNS"
echo "$FAVICON"
echo "$SITE_LOGO"
