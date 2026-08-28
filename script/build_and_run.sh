#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Limits"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Limits.xcodeproj"
SCHEME="Limits"
CONFIGURATION="${LIMITS_CONFIGURATION:-Debug}"
DERIVED_DATA="${LIMITS_DERIVED_DATA:-$ROOT_DIR/.build/xcode-run}"
APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

build_app() {
  local args=(
    -project "$PROJECT"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination "platform=macOS,arch=arm64"
    -derivedDataPath "$DERIVED_DATA"
  )

  if [[ "${LIMITS_CODE_SIGNING_ALLOWED:-1}" == "0" ]]; then
    args+=(CODE_SIGNING_ALLOWED=NO)
  fi

  xcodebuild "${args[@]}" build
  [[ -d "$APP_BUNDLE" ]] || { echo "missing Xcode product: $APP_BUNDLE" >&2; exit 1; }
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

stop_running_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

build_app

case "$MODE" in
  run)
    stop_running_app
    open_app
    ;;
  --debug|debug)
    stop_running_app
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    stop_running_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    stop_running_app
    open_app
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.amir.Limits"'
    ;;
  --verify|verify)
    "$ROOT_DIR/script/verify_runtime.sh" --static-only "$APP_BUNDLE"
    ;;
  --verify-ui|verify-ui)
    "$ROOT_DIR/script/verify_runtime.sh" "$APP_BUNDLE"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--verify-ui]" >&2
    exit 2
    ;;
esac
