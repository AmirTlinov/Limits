#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?Usage: $0 VERSION PREVIOUS_ARCHIVE [FEED_URL]}"
PREVIOUS_ARCHIVE="${2:?Usage: $0 VERSION PREVIOUS_ARCHIVE [FEED_URL]}"
FEED_URL="${3:-https://amirtlinov.github.io/Limits/appcast.xml}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_CHECKOUT="${LIMITS_SPARKLE_CHECKOUT:-$ROOT_DIR/.build/SourcePackages/checkouts/Sparkle}"
DERIVED_DATA="${LIMITS_SPARKLE_CLI_DERIVED_DATA:-$ROOT_DIR/.build/sparkle-cli}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/limits-sparkle-update.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

[[ -f "$PREVIOUS_ARCHIVE" ]] || { echo "Previous release archive is missing: $PREVIOUS_ARCHIVE" >&2; exit 1; }
[[ -d "$SPARKLE_CHECKOUT/Sparkle.xcodeproj" ]] || { echo "Pinned Sparkle checkout is missing: $SPARKLE_CHECKOUT" >&2; exit 1; }

xcodebuild \
  -project "$SPARKLE_CHECKOUT/Sparkle.xcodeproj" \
  -scheme sparkle-cli \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

SPARKLE_CLI="$DERIVED_DATA/Build/Products/Release/sparkle.app/Contents/MacOS/sparkle"
[[ -x "$SPARKLE_CLI" ]] || { echo "Sparkle CLI was not built: $SPARKLE_CLI" >&2; exit 1; }

ditto -x -k "$PREVIOUS_ARCHIVE" "$WORK_DIR/previous"
PREVIOUS_APP="$(find "$WORK_DIR/previous" -maxdepth 3 -type d -name Limits.app -print -quit)"
[[ -n "$PREVIOUS_APP" ]] || { echo "Previous archive does not contain Limits.app" >&2; exit 1; }
PREVIOUS_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PREVIOUS_APP/Contents/Info.plist")"
[[ "$PREVIOUS_VERSION" != "$VERSION" ]] || { echo "Previous archive already contains $VERSION" >&2; exit 1; }

"$SPARKLE_CLI" \
  --check-immediately \
  --allow-major-upgrades \
  --feed-url "$FEED_URL" \
  --user-agent-name LimitsReleaseVerifier \
  --verbose \
  "$PREVIOUS_APP"

for _ in $(seq 1 120); do
  INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PREVIOUS_APP/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$INSTALLED_VERSION" == "$VERSION" ]] && break
  sleep 1
done
[[ "${INSTALLED_VERSION:-}" == "$VERSION" ]] || {
  echo "Sparkle finished without replacing $PREVIOUS_VERSION with $VERSION (found ${INSTALLED_VERSION:-missing})." >&2
  exit 1
}

codesign --verify --deep --strict --verbose=2 "$PREVIOUS_APP"
xcrun stapler validate "$PREVIOUS_APP"
printf 'Sparkle updated the isolated app from %s to %s\n' "$PREVIOUS_VERSION" "$VERSION"
