#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-0.1.0}"
APP_NAME="Limits"
BUNDLE_ID="com.amir.Limits"
MIN_SYSTEM_VERSION="14.0"
ARCH="$(uname -m)"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/codesign.sh"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/Assets/AppIcon.icns"
APP_ICON_FILE="AppIcon.icns"
ZIP_PATH="$DIST_DIR/$APP_NAME-v$VERSION-macOS-$ARCH.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"

cd "$ROOT_DIR"
rm -rf "$APP_BUNDLE" "$ZIP_PATH" "$CHECKSUM_PATH"

swift build -c release
BUILD_BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"

mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$APP_ICON_SOURCE" "$APP_RESOURCES/$APP_ICON_FILE"

if [[ -d "$ROOT_DIR/Sources/Limits/Resources" ]]; then
  cp -R "$ROOT_DIR/Sources/Limits/Resources/"*.lproj "$APP_RESOURCES/"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
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
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

limits_sign_app "$APP_BUNDLE"
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

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
