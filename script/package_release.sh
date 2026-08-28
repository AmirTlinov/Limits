#!/usr/bin/env bash
set -euo pipefail

VERSION=""
NOTARIZE="${LIMITS_NOTARIZE:-0}"
NOTARY_PROFILE="${LIMITS_NOTARY_PROFILE:-LimitsNotary}"
NOTARY_PROFILE_EXPLICIT="false"
NOTARY_TIMEOUT="${LIMITS_NOTARY_TIMEOUT:-30m}"

usage() {
  cat <<'USAGE'
Usage: ./script/package_release.sh [version] [options]

Archives Limits with Xcode, Developer ID signs the complete bundle, and creates
the Sparkle-ready release zip and SHA-256 checksum.

Options:
  --notarize              Submit to Apple, wait, staple, and validate.
  --no-notarize           Build the signed archive without notarization.
  --notary-profile NAME   notarytool Keychain profile (default: LimitsNotary).
  --notary-timeout VALUE  notarytool wait timeout (default: 30m).
  -h, --help              Show this help.

Notary auth may also come from:
  LIMITS_NOTARY_KEY + LIMITS_NOTARY_KEY_ID + LIMITS_NOTARY_ISSUER
  LIMITS_NOTARY_APPLE_ID + LIMITS_NOTARY_PASSWORD + LIMITS_NOTARY_TEAM_ID
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notarize)
      NOTARIZE="1"
      shift
      ;;
    --no-notarize)
      NOTARIZE="0"
      shift
      ;;
    --notary-profile)
      NOTARY_PROFILE="${2:?--notary-profile requires a value}"
      NOTARY_PROFILE_EXPLICIT="true"
      shift 2
      ;;
    --notary-timeout)
      NOTARY_TIMEOUT="${2:?--notary-timeout requires a value}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      [[ -z "$VERSION" ]] || { echo "Unexpected extra argument: $1" >&2; exit 2; }
      VERSION="$1"
      shift
      ;;
  esac
done

VERSION="${VERSION:-1.0.0}"
[[ "$VERSION" =~ ^[0-9]+([.][0-9]+){1,2}([.-][0-9A-Za-z.-]+)?$ ]] || {
  echo "Invalid version: $VERSION" >&2
  exit 2
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Limits"
APP_TEAM_ID="${LIMITS_APP_GROUP_TEAM_ID:-M94V58FCVP}"
BUILD_NUMBER="${LIMITS_BUILD_NUMBER:-$VERSION}"
[[ "$BUILD_NUMBER" =~ ^[0-9]+([.][0-9]+){0,2}$ ]] || {
  echo "CFBundleVersion must be numeric; set LIMITS_BUILD_NUMBER for prereleases." >&2
  exit 2
}
DERIVED_DATA="$ROOT_DIR/.build/xcode-release"
SOURCE_PACKAGES="$ROOT_DIR/.build/SourcePackages"
ARCHIVE_PATH="$ROOT_DIR/.build/release/Limits.xcarchive"
DIST_DIR="$ROOT_DIR/dist"
PACKAGE_DIR="$ROOT_DIR/.build/release/package"
APP_BUNDLE="$PACKAGE_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME-v$VERSION-macOS-arm64.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"
NOTARY_ZIP="$ROOT_DIR/.build/release/$APP_NAME-v$VERSION-notary.zip"
LIMITS_NOTARY_AUTH_ARGS=()

find_developer_id_identity() {
  if [[ -n "${LIMITS_CODESIGN_IDENTITY:-}" ]]; then
    printf '%s\n' "$LIMITS_CODESIGN_IDENTITY"
    return
  fi
  security find-identity -p codesigning -v 2>/dev/null \
    | awk -F '"' -v team="($APP_TEAM_ID)" \
        '/Developer ID Application:/ && index($0, team) { print $2; exit }'
}

create_zip() {
  local output_path="$1"
  rm -f "$output_path"
  mkdir -p "$(dirname "$output_path")"
  (
    cd "$(dirname "$APP_BUNDLE")"
    COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$(basename "$APP_BUNDLE")" "$output_path"
  )
}

configure_notary_auth() {
  if [[ "$NOTARY_PROFILE_EXPLICIT" == "true" || -n "${LIMITS_NOTARY_PROFILE:-}" ]]; then
    LIMITS_NOTARY_AUTH_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  elif [[ -n "${LIMITS_NOTARY_KEY:-}" || -n "${LIMITS_NOTARY_KEY_ID:-}" || -n "${LIMITS_NOTARY_ISSUER:-}" ]]; then
    [[ -n "${LIMITS_NOTARY_KEY:-}" && -n "${LIMITS_NOTARY_KEY_ID:-}" && -n "${LIMITS_NOTARY_ISSUER:-}" ]] || {
      echo "Set LIMITS_NOTARY_KEY, LIMITS_NOTARY_KEY_ID, and LIMITS_NOTARY_ISSUER together." >&2
      exit 1
    }
    LIMITS_NOTARY_AUTH_ARGS=(
      --key "$LIMITS_NOTARY_KEY"
      --key-id "$LIMITS_NOTARY_KEY_ID"
      --issuer "$LIMITS_NOTARY_ISSUER"
    )
  elif [[ -n "${LIMITS_NOTARY_APPLE_ID:-}" || -n "${LIMITS_NOTARY_PASSWORD:-}" || -n "${LIMITS_NOTARY_TEAM_ID:-}" ]]; then
    [[ -n "${LIMITS_NOTARY_APPLE_ID:-}" && -n "${LIMITS_NOTARY_PASSWORD:-}" && -n "${LIMITS_NOTARY_TEAM_ID:-}" ]] || {
      echo "Set LIMITS_NOTARY_APPLE_ID, LIMITS_NOTARY_PASSWORD, and LIMITS_NOTARY_TEAM_ID together." >&2
      exit 1
    }
    LIMITS_NOTARY_AUTH_ARGS=(
      --apple-id "$LIMITS_NOTARY_APPLE_ID"
      --password "$LIMITS_NOTARY_PASSWORD"
      --team-id "$LIMITS_NOTARY_TEAM_ID"
    )
  else
    LIMITS_NOTARY_AUTH_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  fi
}

IDENTITY="$(find_developer_id_identity)"
[[ -n "$IDENTITY" ]] || { echo "A Developer ID Application identity is required." >&2; exit 1; }
[[ "$IDENTITY" == *"($APP_TEAM_ID)" ]] || {
  echo "Signing identity does not belong to team $APP_TEAM_ID: $IDENTITY" >&2
  exit 1
}

cd "$ROOT_DIR"
mkdir -p "$ROOT_DIR/.build" "$DIST_DIR" "$PACKAGE_DIR" "$(dirname "$ARCHIVE_PATH")"
touch "$ROOT_DIR/.build/.metadata_never_index"
rm -rf "$DERIVED_DATA" "$ARCHIVE_PATH" "$APP_BUNDLE" "$ZIP_PATH" "$CHECKSUM_PATH" "$NOTARY_ZIP"

xcodebuild \
  -project Limits.xcodeproj \
  -scheme Limits \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$APP_TEAM_ID" \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  OTHER_CODE_SIGN_FLAGS=--timestamp

ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
[[ -d "$ARCHIVED_APP" ]] || { echo "Archive did not contain $ARCHIVED_APP" >&2; exit 1; }
ditto "$ARCHIVED_APP" "$APP_BUNDLE"
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
WIDGET="$APP_BUNDLE/Contents/PlugIns/LimitsWidgetExtension.appex"
SPARKLE="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
LICENSE_FILE="$APP_BUNDLE/Contents/Resources/LICENSE"
THIRD_PARTY_NOTICES="$APP_BUNDLE/Contents/Resources/THIRD_PARTY_NOTICES.md"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")" == "$VERSION" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")" == "$BUILD_NUMBER" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO_PLIST")" == "https://amirtlinov.github.io/Limits/appcast.xml" ]]
[[ -d "$WIDGET" ]] || { echo "Widget extension is missing from release app." >&2; exit 1; }
[[ -d "$SPARKLE" ]] || { echo "Sparkle.framework is missing from release app." >&2; exit 1; }
[[ -s "$LICENSE_FILE" ]] || { echo "MIT license is missing from release app." >&2; exit 1; }
[[ -s "$THIRD_PARTY_NOTICES" ]] || { echo "Third-party notices are missing from release app." >&2; exit 1; }
[[ "$(lipo -archs "$APP_BUNDLE/Contents/MacOS/$APP_NAME")" == "arm64" ]]
[[ "$(lipo -archs "$WIDGET/Contents/MacOS/LimitsWidgetExtension")" == "arm64" ]]

"$ROOT_DIR/script/verify_widget_extension.sh" --static-only "$APP_BUNDLE"
codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 | grep -F "TeamIdentifier=$APP_TEAM_ID" >/dev/null
codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 | grep -F "Runtime Version=" >/dev/null
codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 | grep -F "Timestamp=" >/dev/null

if [[ "$NOTARIZE" == "1" || "$NOTARIZE" == "true" || "$NOTARIZE" == "yes" ]]; then
  configure_notary_auth
  create_zip "$NOTARY_ZIP"
  xcrun notarytool submit "$NOTARY_ZIP" "${LIMITS_NOTARY_AUTH_ARGS[@]}" --wait --timeout "$NOTARY_TIMEOUT"
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
  spctl -a -t exec -vvv "$APP_BUNDLE"
  rm -f "$NOTARY_ZIP"
fi

create_zip "$ZIP_PATH"
(
  cd "$DIST_DIR"
  shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$CHECKSUM_PATH")"
)

printf '%s\n' "$APP_BUNDLE" "$ZIP_PATH" "$CHECKSUM_PATH"
