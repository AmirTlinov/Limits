#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Limits"
EXPECTED_BUNDLE="${1:-}"
EXPECTED_BINARY=""
if [[ -n "$EXPECTED_BUNDLE" ]]; then
  EXPECTED_BINARY="$EXPECTED_BUNDLE/Contents/MacOS/$APP_NAME"
fi

fail() {
  echo "runtime verify failed: $*" >&2
  exit 1
}

wait_for_process() {
  local pids=()
  for _ in {1..40}; do
    mapfile -t pids < <(pgrep -x "$APP_NAME" || true)
    if (( ${#pids[@]} > 0 )); then
      printf '%s\n' "${pids[@]}"
      return 0
    fi
    sleep 0.25
  done
  return 1
}

mapfile -t PIDS < <(wait_for_process) || fail "process $APP_NAME did not start"
(( ${#PIDS[@]} == 1 )) || fail "expected one $APP_NAME process, got ${#PIDS[@]}: ${PIDS[*]}"
PID="${PIDS[0]}"
COMMAND="$(ps -p "$PID" -o command= | sed 's/^ *//')"
echo "process: pid=$PID command=$COMMAND"

if [[ -n "$EXPECTED_BINARY" && "$COMMAND" != "$EXPECTED_BINARY"* ]]; then
  fail "expected binary $EXPECTED_BINARY, got $COMMAND"
fi

if [[ -n "$EXPECTED_BUNDLE" ]]; then
  LSUIELEMENT="$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$EXPECTED_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$LSUIELEMENT" == "true" ]] || fail "LSUIElement is not true for $EXPECTED_BUNDLE"
  echo "bundle: LSUIElement=true"
fi

count_windows() {
  swift - "$APP_NAME" <<'SWIFT'
import CoreGraphics
import Foundation

let appName = CommandLine.arguments[1]
let windows = CGWindowListCopyWindowInfo([.optionAll], CGWindowID(0)) as? [[String: Any]] ?? []
let matching = windows.filter { window in
    let owner = window[kCGWindowOwnerName as String] as? String
    let name = window[kCGWindowName as String] as? String
    return owner == appName && name == "Лимиты"
}
print(matching.count)
SWIFT
}

WINDOW_COUNT="0"
for _ in {1..40}; do
  WINDOW_COUNT="$(count_windows)"
  if [[ "$WINDOW_COUNT" == "1" ]]; then
    break
  fi
  if [[ "$WINDOW_COUNT" != "0" ]]; then
    fail "expected exactly one Limits window, got $WINDOW_COUNT"
  fi
  sleep 0.25
done
[[ "$WINDOW_COUNT" == "1" ]] || fail "expected exactly one Limits window, got $WINDOW_COUNT"
echo "window: count=1"

find_tray_item() {
  osascript <<'OSA' 2>/dev/null || true
tell application "System Events"
  tell process "Limits"
    repeat with mb in menu bars
      repeat with mbi in menu bar items of mb
        set candidate to ""
        try
          set candidate to candidate & " " & (name of mbi as text)
        end try
        try
          set candidate to candidate & " " & (description of mbi as text)
        end try
        try
          set candidate to candidate & " " & (help of mbi as text)
        end try
        try
          set candidate to candidate & " " & (value of attribute "AXTitle" of mbi as text)
        end try
        if candidate contains "Codex" or candidate contains "Claude" or candidate contains "5ч лимит" then
          return candidate
        end if
      end repeat
    end repeat
  end tell
end tell
return ""
OSA
}

TRAY_ITEM=""
for _ in {1..40}; do
  TRAY_ITEM="$(find_tray_item)"
  if [[ -n "$TRAY_ITEM" ]]; then
    break
  fi
  sleep 0.25
done
[[ -n "$TRAY_ITEM" ]] || fail "tray item was not visible through Accessibility"
echo "tray: $TRAY_ITEM"
