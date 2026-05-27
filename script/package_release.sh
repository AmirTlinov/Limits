#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-0.1.0}"
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
rm -rf "$APP_BUNDLE" "$ZIP_PATH" "$CHECKSUM_PATH"

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
(
  cd "$DIST_DIR"
  COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$APP_NAME.app" "$(basename "$ZIP_PATH")"
)
(
  cd "$DIST_DIR"
  shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$CHECKSUM_PATH")"
)

codesign --verify --deep --strict "$APP_BUNDLE"

echo "$ZIP_PATH"
echo "$CHECKSUM_PATH"
