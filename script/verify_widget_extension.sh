#!/usr/bin/env bash
set -euo pipefail

APP_PATH="/Applications/Limits.app"
REFRESH_CHRONOD="false"
WIDGET_NAME="LimitsWidgetExtension"
WIDGET_BUNDLE_ID="com.amir.Limits.WidgetExtension"
CHRONOD_DB="$HOME/Library/Group Containers/group.com.apple.chronod/chronod/chrono.sql"

usage() {
  cat <<USAGE
Usage: $0 [--refresh-chronod] [/Applications/Limits.app]

Verifies the installed Limits WidgetKit extension at the surfaces that matter:
Gatekeeper trust, PlugInKit registration, and chronod WidgetKit ingestion.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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

WIDGET_PATH="$APP_PATH/Contents/PlugIns/$WIDGET_NAME.appex"
FAILURES=0

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

[[ -d "$APP_PATH" ]] || { echo "missing app: $APP_PATH" >&2; exit 1; }
[[ -d "$WIDGET_PATH" ]] || { echo "missing widget extension: $WIDGET_PATH" >&2; exit 1; }

required "spctl app" spctl -a -vvv "$APP_PATH"
optional "spctl widget extension" spctl -a -vvv "$WIDGET_PATH"

# shellcheck disable=SC2016
required "pluginkit registration" bash -c \
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
  echo "widget verification failed at $FAILURES required surface(s)" >&2
  exit 1
fi

echo "widget verification passed"
