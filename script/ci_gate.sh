#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="local"

usage() {
  cat <<USAGE
Usage: $0 [--isolated-ui]

Without arguments, runs the complete non-interactive local gate. The optional
UI gate is reserved for a dedicated macOS session and requires
LIMITS_ISOLATED_UI_SESSION=1.
USAGE
}

case "${1:-}" in
  "") ;;
  --isolated-ui)
    MODE="isolated-ui"
    shift
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
[[ $# -eq 0 ]] || { usage >&2; exit 2; }

if [[ "$MODE" == "isolated-ui" ]]; then
  "$ROOT_DIR/script/require_isolated_ui_session.sh"
fi

DERIVED_DATA="${LIMITS_CI_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Limits-CI}"
SOURCE_PACKAGES="${LIMITS_SOURCE_PACKAGES:-$ROOT_DIR/.build/SourcePackages}"
DESTINATION="platform=macOS,arch=arm64"
COMMON_XCODE_ARGS=(
  -project "$ROOT_DIR/Limits.xcodeproj"
  -configuration Debug
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED_DATA"
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES"
  CODE_SIGNING_ALLOWED=NO
)
APP_XCODE_ARGS=(-scheme Limits "${COMMON_XCODE_ARGS[@]}")
UNIT_TEST_XCODE_ARGS=(-scheme LimitsUnitTests "${COMMON_XCODE_ARGS[@]}")
UI_TEST_XCODE_ARGS=(-scheme LimitsUITests "${COMMON_XCODE_ARGS[@]}")

project_receipt() {
  find "$ROOT_DIR/Limits.xcodeproj" -path '*/xcuserdata' -prune -o -type f -print \
    | LC_ALL=C sort \
    | while IFS= read -r file; do shasum -a 256 "$file"; done
}

cd "$ROOT_DIR"
./script/verify_localizations.py
plutil -lint Config/*.plist Config/*.entitlements Sources/LimitsShared/Resources/*.lproj/Localizable.strings >/dev/null
for script in script/*.sh; do bash -n "$script"; done
./script/generate_app_icon.sh --check
xcrun swift ./script/mask_screenshot_corners.swift --check \
  docs/images/limits-window.png \
  docs/images/limits-window-dark.png \
  docs/images/limits-tray.png
PROJECT_BEFORE="$(project_receipt)"
./script/generate_xcode_project.rb
PROJECT_AFTER="$(project_receipt)"
if [[ "$PROJECT_BEFORE" != "$PROJECT_AFTER" ]]; then
  git diff -- Limits.xcodeproj >&2
  echo "Limits.xcodeproj is stale; run ./script/generate_xcode_project.rb" >&2
  exit 1
fi
xcodebuild "${APP_XCODE_ARGS[@]}" build
xcodebuild "${UNIT_TEST_XCODE_ARGS[@]}" test
./script/verify_runtime.sh --static-only "$DERIVED_DATA/Build/Products/Debug/Limits.app"

if [[ "$MODE" == "isolated-ui" ]]; then
  xcodebuild "${UI_TEST_XCODE_ARGS[@]}" LIMITS_ISOLATED_UI_SESSION=1 test
  ./script/verify_runtime.sh "$DERIVED_DATA/Build/Products/Debug/Limits.app"
else
  echo "Local gate passed without taking over the interactive macOS session."
  echo "GitHub Actions owns the isolated UI and lifecycle gate."
fi
