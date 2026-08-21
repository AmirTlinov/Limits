#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${LIMITS_CI_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Limits-CI}"
SOURCE_PACKAGES="${LIMITS_SOURCE_PACKAGES:-$ROOT_DIR/.build/SourcePackages}"
DESTINATION="platform=macOS,arch=arm64"
XCODE_ARGS=(
  -project "$ROOT_DIR/Limits.xcodeproj"
  -scheme Limits
  -configuration Debug
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED_DATA"
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES"
  CODE_SIGNING_ALLOWED=NO
)

cd "$ROOT_DIR"
./script/verify_localizations.py
plutil -lint Config/*.plist Config/*.entitlements Sources/LimitsShared/Resources/*.lproj/Localizable.strings >/dev/null
for script in script/*.sh; do bash -n "$script"; done
./script/generate_xcode_project.rb
git diff --exit-code -- Limits.xcodeproj
xcodebuild "${XCODE_ARGS[@]}" build
xcodebuild "${XCODE_ARGS[@]}" test -only-testing:LimitsTests
xcodebuild "${XCODE_ARGS[@]}" test -only-testing:LimitsUITests
./script/verify_runtime.sh "$DERIVED_DATA/Build/Products/Debug/Limits.app"
