#!/usr/bin/env bash
set -euo pipefail

VERSION=""
NOTARIZE="${LIMITS_NOTARIZE:-0}"
NOTARY_PROFILE="${LIMITS_NOTARY_PROFILE:-LimitsNotary}"
NOTARY_PROFILE_EXPLICIT="false"
NOTARY_TIMEOUT="${LIMITS_NOTARY_TIMEOUT:-30m}"

usage() {
  cat <<USAGE
Usage: $0 [version] [--notarize] [--notary-profile NAME] [--notary-timeout 30m]

Builds, signs, and zips Limits.app.

Options:
  --notarize              Submit the app to Apple notary service, staple it,
                          validate the ticket, then recreate the final zip.
  --notary-profile NAME   Keychain profile created by notarytool
                          store-credentials. Defaults to LimitsNotary.
  --notary-timeout VALUE  notarytool wait timeout. Defaults to 30m.
  -h, --help              Show this help.

Notary auth can also come from env:
  LIMITS_NOTARY_PROFILE
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
      if [[ -n "$VERSION" ]]; then
        echo "Unexpected extra argument: $1" >&2
        usage >&2
        exit 2
      fi
      VERSION="$1"
      shift
      ;;
  esac
done

VERSION="${VERSION:-0.1.0}"
APP_NAME="Limits"
APP_BUNDLE_ID="com.amir.Limits"
WIDGET_NAME="LimitsWidgetExtension"
WIDGET_BUNDLE_ID="com.amir.Limits.WidgetExtension"
APP_GROUP_TEAM_ID="${LIMITS_APP_GROUP_TEAM_ID:-M94V58FCVP}"
APP_GROUP_ID="${LIMITS_APP_GROUP_ID:-$APP_GROUP_TEAM_ID.com.amir.Limits.shared}"
MIN_SYSTEM_VERSION="14.0"
ARCH="$(uname -m)"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/codesign.sh"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_PLUGINS="$APP_CONTENTS/PlugIns"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/Assets/AppIcon.icns"
APP_ICON_FILE="AppIcon.icns"
WIDGET_BUNDLE="$APP_PLUGINS/$WIDGET_NAME.appex"
WIDGET_CONTENTS="$WIDGET_BUNDLE/Contents"
WIDGET_MACOS="$WIDGET_CONTENTS/MacOS"
WIDGET_BINARY="$WIDGET_MACOS/$WIDGET_NAME"
WIDGET_INFO_PLIST="$WIDGET_CONTENTS/Info.plist"
ENTITLEMENTS_DIR="$DIST_DIR/Entitlements"
APP_ENTITLEMENTS="$ENTITLEMENTS_DIR/$APP_NAME.entitlements"
WIDGET_ENTITLEMENTS="$ENTITLEMENTS_DIR/$WIDGET_NAME.entitlements"
ZIP_PATH="$DIST_DIR/$APP_NAME-v$VERSION-macOS-$ARCH.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"
NOTARY_SUBMIT_ZIP_PATH="$DIST_DIR/$APP_NAME-v$VERSION-macOS-$ARCH-notary-submit.zip"
LIMITS_NOTARY_AUTH_ARGS=()

create_zip() {
  local output_path="$1"
  rm -f "$output_path"
  (
    cd "$DIST_DIR"
    COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$APP_NAME.app" "$(basename "$output_path")"
  )
}

write_checksum() {
  local input_path="$1"
  local output_path="$2"
  rm -f "$output_path"
  (
    cd "$DIST_DIR"
    shasum -a 256 "$(basename "$input_path")" > "$(basename "$output_path")"
  )
}

configure_notary_auth_args() {
  LIMITS_NOTARY_AUTH_ARGS=()

  if [[ "$NOTARY_PROFILE_EXPLICIT" == "true" || -n "${LIMITS_NOTARY_PROFILE:-}" ]]; then
    LIMITS_NOTARY_AUTH_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    return
  fi

  if [[ -n "${LIMITS_NOTARY_KEY:-}" || -n "${LIMITS_NOTARY_KEY_ID:-}" || -n "${LIMITS_NOTARY_ISSUER:-}" ]]; then
    if [[ -z "${LIMITS_NOTARY_KEY:-}" || -z "${LIMITS_NOTARY_KEY_ID:-}" || -z "${LIMITS_NOTARY_ISSUER:-}" ]]; then
      echo "notarytool: set LIMITS_NOTARY_KEY, LIMITS_NOTARY_KEY_ID, and LIMITS_NOTARY_ISSUER together" >&2
      exit 1
    fi
    LIMITS_NOTARY_AUTH_ARGS=(--key "$LIMITS_NOTARY_KEY" --key-id "$LIMITS_NOTARY_KEY_ID" --issuer "$LIMITS_NOTARY_ISSUER")
    return
  fi

  if [[ -n "${LIMITS_NOTARY_APPLE_ID:-}" || -n "${LIMITS_NOTARY_PASSWORD:-}" || -n "${LIMITS_NOTARY_TEAM_ID:-}" ]]; then
    if [[ -z "${LIMITS_NOTARY_APPLE_ID:-}" || -z "${LIMITS_NOTARY_TEAM_ID:-}" ]]; then
      echo "notarytool: set LIMITS_NOTARY_APPLE_ID and LIMITS_NOTARY_TEAM_ID together" >&2
      exit 1
    fi
    LIMITS_NOTARY_AUTH_ARGS=(--apple-id "$LIMITS_NOTARY_APPLE_ID" --team-id "$LIMITS_NOTARY_TEAM_ID")
    if [[ -n "${LIMITS_NOTARY_PASSWORD:-}" ]]; then
      LIMITS_NOTARY_AUTH_ARGS+=(--password "$LIMITS_NOTARY_PASSWORD")
    elif [[ ! -t 0 ]]; then
      echo "notarytool: LIMITS_NOTARY_PASSWORD is required for non-interactive Apple ID auth; or use a keychain profile" >&2
      exit 1
    fi
    return
  fi

  LIMITS_NOTARY_AUTH_ARGS=(--keychain-profile "$NOTARY_PROFILE")
}

notarize_and_staple_app() {
  configure_notary_auth_args

  create_zip "$NOTARY_SUBMIT_ZIP_PATH"
  echo "notarytool: submitting $(basename "$NOTARY_SUBMIT_ZIP_PATH")"
  if ! xcrun notarytool submit "$NOTARY_SUBMIT_ZIP_PATH" "${LIMITS_NOTARY_AUTH_ARGS[@]}" --wait --timeout "$NOTARY_TIMEOUT"; then
    cat >&2 <<ERROR

notarytool failed.

Create the default keychain profile, then rerun:
  ./script/store_notary_credentials.sh "$NOTARY_PROFILE"
  ./script/package_release.sh "$VERSION" --notarize

Or provide App Store Connect API env:
  LIMITS_NOTARY_KEY
  LIMITS_NOTARY_KEY_ID
  LIMITS_NOTARY_ISSUER
ERROR
    exit 1
  fi

  echo "stapler: stapling $APP_BUNDLE"
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
  spctl -a -vvv "$APP_BUNDLE"
  rm -f "$NOTARY_SUBMIT_ZIP_PATH"
}

write_app_group_entitlements() {
  local path="$1"
  local sandbox="${2:-false}"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
PLIST
  if [[ "$sandbox" == "true" ]]; then
    cat >>"$path" <<PLIST
  <key>com.apple.security.app-sandbox</key>
  <true/>
PLIST
  fi
  cat >>"$path" <<PLIST
  <key>com.apple.security.application-groups</key>
  <array>
    <string>$APP_GROUP_ID</string>
  </array>
</dict>
</plist>
PLIST
}

cd "$ROOT_DIR"
limits_require_codesign_team "$APP_GROUP_TEAM_ID"
rm -rf "$APP_BUNDLE" "$ZIP_PATH" "$CHECKSUM_PATH" "$NOTARY_SUBMIT_ZIP_PATH"

swift build -c release --product "$APP_NAME"
swift build -c release --product "$WIDGET_NAME"
BUILD_DIR="$(swift build -c release --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"
BUILD_WIDGET_BINARY="$BUILD_DIR/$WIDGET_NAME"

mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$WIDGET_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$BUILD_WIDGET_BINARY" "$WIDGET_BINARY"
chmod +x "$WIDGET_BINARY"
cp "$APP_ICON_SOURCE" "$APP_RESOURCES/$APP_ICON_FILE"

if [[ -d "$ROOT_DIR/Sources/Limits/Resources" ]]; then
  cp -R "$ROOT_DIR/Sources/Limits/Resources/." "$APP_RESOURCES/"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$APP_BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>ru</string>
    <string>zh-Hans</string>
    <string>fr</string>
    <string>es</string>
  </array>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>CFBundleIconFile</key>
  <string>$APP_ICON_FILE</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>$APP_BUNDLE_ID</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>limits</string>
      </array>
    </dict>
  </array>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LimitsAppGroupIdentifier</key>
  <string>$APP_GROUP_ID</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

cat >"$WIDGET_INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$WIDGET_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$WIDGET_BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$WIDGET_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>Limits</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>CFBundlePackageType</key>
  <string>XPC!</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>MacOSX</string>
  </array>
  <key>MinimumOSVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LimitsAppGroupIdentifier</key>
  <string>$APP_GROUP_ID</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.widgetkit-extension</string>
  </dict>
</dict>
</plist>
PLIST

write_app_group_entitlements "$APP_ENTITLEMENTS"
write_app_group_entitlements "$WIDGET_ENTITLEMENTS" true
plutil -lint "$INFO_PLIST" "$WIDGET_INFO_PLIST" "$APP_ENTITLEMENTS" "$WIDGET_ENTITLEMENTS" >/dev/null
xattr -cr "$APP_BUNDLE" 2>/dev/null || true
limits_sign_path "$WIDGET_BUNDLE" "$WIDGET_ENTITLEMENTS"
limits_sign_app "$APP_BUNDLE" "$APP_ENTITLEMENTS"

mkdir -p "$DIST_DIR"
codesign --verify --deep --strict "$APP_BUNDLE"

if [[ "$NOTARIZE" == "1" || "$NOTARIZE" == "true" || "$NOTARIZE" == "yes" ]]; then
  notarize_and_staple_app
fi

create_zip "$ZIP_PATH"
write_checksum "$ZIP_PATH" "$CHECKSUM_PATH"

echo "$ZIP_PATH"
echo "$CHECKSUM_PATH"
