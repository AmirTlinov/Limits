#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT_DIR/script/require_isolated_ui_session.sh"
OUTPUT_DIR="${1:-$ROOT_DIR/docs/images}"
REQUEST_FILE="$ROOT_DIR/.build/documentation-screenshot-output"
RESULT_BUNDLE="$ROOT_DIR/.build/screenshots/Documentation.xcresult"
ATTACHMENTS_DIR="$ROOT_DIR/.build/screenshots/DocumentationAttachments"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$(dirname "$REQUEST_FILE")"
printf 'requested\n' > "$REQUEST_FILE"
trap 'rm -f "$REQUEST_FILE"' EXIT
rm -rf "$RESULT_BUNDLE" "$ATTACHMENTS_DIR"

xcodebuild test \
  -project "$ROOT_DIR/Limits.xcodeproj" \
  -scheme LimitsUITests \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$ROOT_DIR/.build/screenshots" \
  -clonedSourcePackagesDirPath "$ROOT_DIR/.build/SourcePackages" \
  -resultBundlePath "$RESULT_BUNDLE" \
  LIMITS_ISOLATED_UI_SESSION=1 \
  -only-testing:LimitsUITests/LimitsUITests/testCaptureDocumentationScreenshots

xcrun xcresulttool export attachments \
  --path "$RESULT_BUNDLE" \
  --output-path "$ATTACHMENTS_DIR" >/dev/null

python3 - "$ATTACHMENTS_DIR/manifest.json" "$ATTACHMENTS_DIR" "$OUTPUT_DIR" <<'PY'
import json
import pathlib
import shutil
import sys

manifest_path = pathlib.Path(sys.argv[1])
attachments_dir = pathlib.Path(sys.argv[2])
output_dir = pathlib.Path(sys.argv[3])
manifest = json.loads(manifest_path.read_text())
wanted = {"limits-window.png", "limits-window-dark.png", "limits-tray.png"}
copied = set()

def visit(value):
    if isinstance(value, dict):
        name = value.get("name")
        suggested = value.get("suggestedHumanReadableName", "")
        if not name:
            for candidate in wanted:
                stem = pathlib.Path(candidate).stem
                if suggested.startswith(stem + "_"):
                    name = candidate
                    break
        exported = value.get("exportedFileName") or value.get("filename")
        if name in wanted and exported:
            source = attachments_dir / exported
            if source.is_file():
                shutil.copy2(source, output_dir / name)
                copied.add(name)
        for child in value.values():
            visit(child)
    elif isinstance(value, list):
        for child in value:
            visit(child)

visit(manifest)
missing = wanted - copied
if missing:
    raise SystemExit(f"Missing screenshot attachments: {sorted(missing)}")
PY

test -s "$OUTPUT_DIR/limits-window.png"
test -s "$OUTPUT_DIR/limits-window-dark.png"
test -s "$OUTPUT_DIR/limits-tray.png"
xcrun swift "$ROOT_DIR/script/mask_screenshot_corners.swift" \
  "$OUTPUT_DIR/limits-window.png" \
  "$OUTPUT_DIR/limits-window-dark.png" \
  "$OUTPUT_DIR/limits-tray.png"
printf '%s\n' "$OUTPUT_DIR/limits-window.png" "$OUTPUT_DIR/limits-window-dark.png" "$OUTPUT_DIR/limits-tray.png"
