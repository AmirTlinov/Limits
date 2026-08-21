#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

cd "$ROOT_DIR"
./script/verify_localizations.py
plutil -lint Config/*.plist Config/*.entitlements Sources/LimitsShared/Resources/*.lproj/Localizable.strings >/dev/null
for script in script/*.sh; do bash -n "$script"; done
./script/generate_xcode_project.rb
git diff --exit-code -- Limits.xcodeproj
xcodebuild "${APP_XCODE_ARGS[@]}" build
xcodebuild "${UNIT_TEST_XCODE_ARGS[@]}" test
xcodebuild "${APP_XCODE_ARGS[@]}" test -only-testing:LimitsUITests
./script/verify_runtime.sh "$DERIVED_DATA/Build/Products/Debug/Limits.app"
