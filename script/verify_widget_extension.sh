#!/usr/bin/env bash
set -euo pipefail

APP_PATH="/Applications/Limits.app"
REFRESH_CHRONOD="false"
STATIC_ONLY="false"
WIDGET_NAME="LimitsWidgetExtension"
WIDGET_BUNDLE_ID="com.amir.Limits.WidgetExtension"
CHRONOD_DB="$HOME/Library/Group Containers/group.com.apple.chronod/chronod/chrono.sql"
FAILURES=0

usage() {
  cat <<USAGE
Usage: $0 [--static-only] [--refresh-chronod] [/Applications/Limits.app]

Always verifies the signed app/widget bundle contract. Without --static-only,
also proves Gatekeeper trust, PlugInKit registration, and chronod ingestion for
an installed, notarized release.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --static-only)
      STATIC_ONLY="true"
      shift
      ;;
    --refresh-chronod)
      REFRESH_CHRONOD="true"
      shift
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
      APP_PATH="$1"
      shift
      ;;
  esac
done

APP_PATH="${APP_PATH%/}"
WIDGET_PATH="$APP_PATH/Contents/PlugIns/$WIDGET_NAME.appex"
APP_INFO="$APP_PATH/Contents/Info.plist"
WIDGET_INFO="$WIDGET_PATH/Contents/Info.plist"
WIDGET_BINARY="$WIDGET_PATH/Contents/MacOS/$WIDGET_NAME"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/limits-widget.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

required() {
  local label="$1"
  shift
  echo "--- $label ---"
  if "$@"; then
    return 0
  fi
  FAILURES=$((FAILURES + 1))
  return 0
}

optional() {
  local label="$1"
  shift
  echo "--- $label ---"
  "$@" || true
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

extract_entitlements() {
  local bundle="$1"
  local output="$2"
  codesign -d --entitlements :- "$bundle" >"$output" 2>/dev/null
  plutil -lint "$output" >/dev/null
}

verify_bundle_contract() {
  [[ -d "$APP_PATH" ]] || { echo "missing app: $APP_PATH" >&2; return 1; }
  [[ -d "$WIDGET_PATH" ]] || { echo "missing widget extension: $WIDGET_PATH" >&2; return 1; }
  [[ -f "$APP_INFO" && -f "$WIDGET_INFO" && -x "$WIDGET_BINARY" ]] || return 1

  [[ "$(plist_value "$WIDGET_INFO" CFBundleIdentifier)" == "$WIDGET_BUNDLE_ID" ]] || return 1
  [[ "$(plist_value "$WIDGET_INFO" NSExtension:NSExtensionPointIdentifier)" == "com.apple.widgetkit-extension" ]] || return 1
  [[ "$(lipo -archs "$WIDGET_BINARY")" == "arm64" ]] || return 1

  [[ -d "$APP_PATH/Contents/Frameworks/LimitsShared.framework" ]] || return 1
  [[ -d "$APP_PATH/Contents/Frameworks/Sparkle.framework" ]] || return 1

  local app_entitlements="$TEMP_DIR/app-entitlements.plist"
  local widget_entitlements="$TEMP_DIR/widget-entitlements.plist"
  extract_entitlements "$APP_PATH" "$app_entitlements" || return 1
  extract_entitlements "$WIDGET_PATH" "$widget_entitlements" || return 1

  local expected_group app_group widget_group widget_sandbox
  expected_group="$(plist_value "$APP_INFO" LimitsAppGroupIdentifier)"
  app_group="$(plist_value "$app_entitlements" 'com.apple.security.application-groups:0')"
  widget_group="$(plist_value "$widget_entitlements" 'com.apple.security.application-groups:0')"
  widget_sandbox="$(plist_value "$widget_entitlements" 'com.apple.security.app-sandbox')"

  [[ -n "$expected_group" ]] || return 1
  [[ "$app_group" == "$expected_group" && "$widget_group" == "$expected_group" ]] || return 1
  [[ "$widget_sandbox" == "true" ]] || return 1

  echo "bundle id: $WIDGET_BUNDLE_ID"
  echo "extension point: com.apple.widgetkit-extension"
  echo "architecture: arm64"
  echo "shared app group: $expected_group"
  echo "widget sandbox: enabled"
  echo "embedded frameworks: LimitsShared, Sparkle"
}

required "strict code-signature graph" codesign --verify --deep --strict --verbose=2 "$APP_PATH"
required "app/widget bundle contract" verify_bundle_contract

if [[ "$STATIC_ONLY" == "true" ]]; then
  if [[ "$FAILURES" -gt 0 ]]; then
    echo "static widget verification failed at $FAILURES required surface(s)" >&2
    exit 1
  fi
  echo "static widget verification passed"
  exit 0
fi

required "Gatekeeper app assessment" spctl -a -vvv "$APP_PATH"
optional "Gatekeeper widget diagnostic" spctl -a -vvv "$WIDGET_PATH"

# shellcheck disable=SC2016
required "PlugInKit registration" bash -c \
  'last_output=""; for _attempt in 1 2 3 4 5 6 7 8 9 10; do last_output="$(pluginkit -m -A -D -v -p com.apple.widgetkit-extension -i "$1" 2>&1)"; if printf "%s\n" "$last_output" | grep -q "$1"; then printf "%s\n" "$last_output" >&2; exit 0; fi; sleep 0.5; done; printf "%s\n" "$last_output" >&2; exit 1' \
  _ "$WIDGET_BUNDLE_ID"

if [[ "$REFRESH_CHRONOD" == "true" ]]; then
  killall chronod 2>/dev/null || true
  sleep 2
fi

# shellcheck disable=SC2016
required "chronod ingestion" bash -c \
  '[[ -f "$1" ]] || exit 1; last_output=""; for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do last_output="$(sqlite3 "$1" "select bundleIdentifier, version from ExtensionMetadata where bundleIdentifier = '\''$2'\'' or bundleIdentifier like '\''%::'\'' || '\''$2'\'';")"; if printf "%s\n" "$last_output" | grep -F -q "$2"; then printf "%s\n" "$last_output" >&2; exit 0; fi; sleep 1; done; printf "%s\n" "$last_output" >&2; exit 1' \
  _ "$CHRONOD_DB" "$WIDGET_BUNDLE_ID"

if [[ "$FAILURES" -gt 0 ]]; then
  echo "live widget verification failed at $FAILURES required surface(s)" >&2
  exit 1
fi

echo "live widget verification passed"
