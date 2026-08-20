#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Limits"
APP_BUNDLE="${1:-}"
EXPECTED_FEED_URL="https://amirtlinov.github.io/Limits/appcast.xml"
EXPECTED_PUBLIC_KEY="t+to52jjoiebTJ/XWpzF4jc3pngvi+W+hkrYuVUqLhQ="

usage() {
  cat <<USAGE
Usage: $0 /path/to/Limits.app

Launches the exact app bundle and proves the native lifecycle end to end:
foreground first launch, tray-only survival after close, and URL-driven reopen.
USAGE
}

fail() {
  echo "runtime verification failed: $*" >&2
  exit 1
}

[[ -n "$APP_BUNDLE" ]] || { usage >&2; exit 2; }
[[ -d "$APP_BUNDLE" ]] || fail "missing app bundle: $APP_BUNDLE"

APP_BUNDLE="$(cd "$APP_BUNDLE" && pwd -P)"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
EXPECTED_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
[[ -f "$INFO_PLIST" ]] || fail "missing Info.plist: $INFO_PLIST"
[[ -x "$EXPECTED_BINARY" ]] || fail "missing executable: $EXPECTED_BINARY"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/limits-runtime.XXXXXX")"
WINDOW_PROBE="$TEMP_DIR/presented-window-count"
LAUNCHED_PID=""

cleanup() {
  if [[ -n "$LAUNCHED_PID" ]] && kill -0 "$LAUNCHED_PID" 2>/dev/null; then
    kill "$LAUNCHED_PID" 2>/dev/null || true
    for _ in {1..20}; do
      kill -0 "$LAUNCHED_PID" 2>/dev/null || break
      sleep 0.1
    done
  fi
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST" 2>/dev/null || true
}

[[ -z "$(plist_value LSUIElement)" ]] || fail "LSUIElement must be absent so a presented window can become a foreground app"
[[ "$(plist_value CFBundleURLTypes:0:CFBundleURLSchemes:0)" == "limits" ]] || fail "limits:// URL scheme is missing"
[[ "$(plist_value SUFeedURL)" == "$EXPECTED_FEED_URL" ]] || fail "unexpected Sparkle feed URL"
[[ "$(plist_value SUPublicEDKey)" == "$EXPECTED_PUBLIC_KEY" ]] || fail "unexpected Sparkle public key"
echo "bundle contract: foreground-capable, limits:// registered, Sparkle feed pinned"

cat >"$TEMP_DIR/presented-window-count.swift" <<'SWIFT'
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
    exit(2)
}

var displayCount: UInt32 = 0
guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success else {
    exit(3)
}
var displayIDs = Array(repeating: CGDirectDisplayID(), count: Int(displayCount))
guard CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount) == .success else {
    exit(3)
}
let displayFrames = displayIDs.prefix(Int(displayCount)).map(CGDisplayBounds)
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], CGWindowID(0)) as? [[String: Any]] ?? []

let count = windows.filter { window in
    guard
        (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
        (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
        frame.width >= 900,
        frame.height >= 550
    else {
        return false
    }
    return displayFrames.contains { $0.intersects(frame) }
}.count

print(count)
SWIFT
xcrun swiftc -O "$TEMP_DIR/presented-window-count.swift" -o "$WINDOW_PROBE"

process_pids() {
  local pid command
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    command="$(ps -p "$pid" -o command= 2>/dev/null | sed 's/^ *//' || true)"
    [[ "$command" == "$EXPECTED_BINARY"* ]] && printf '%s\n' "$pid"
  done < <(pgrep -x "$APP_NAME" 2>/dev/null || true)
}

process_count() {
  process_pids | awk 'NF { count += 1 } END { print count + 0 }'
}

wait_for_process_exit() {
  for _ in {1..40}; do
    [[ "$(process_count)" == "0" ]] && return 0
    sleep 0.25
  done
  return 1
}

wait_for_single_process() {
  local pids
  for _ in {1..60}; do
    pids="$(process_pids)"
    if [[ "$(printf '%s\n' "$pids" | awk 'NF { count += 1 } END { print count + 0 }')" == "1" ]]; then
      printf '%s\n' "$pids"
      return 0
    fi
    sleep 0.25
  done
  return 1
}

presented_window_count() {
  "$WINDOW_PROBE" "$1"
}

wait_for_window_count() {
  local expected="$1"
  local pid="$2"
  local actual=""
  for _ in {1..60}; do
    actual="$(presented_window_count "$pid")"
    [[ "$actual" == "$expected" ]] && return 0
    if [[ "$expected" == "1" && "$actual" != "0" ]]; then
      fail "expected one presented main window, found $actual"
    fi
    sleep 0.25
  done
  fail "expected $expected presented main window(s), found ${actual:-unknown}"
}

tray_item_description() {
  osascript - "$1" <<'OSA' 2>/dev/null || true
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    tell (first application process whose unix id is targetPID)
    repeat with candidateBar in menu bars
      repeat with candidateItem in menu bar items of candidateBar
        set candidate to ""
        try
          set candidate to candidate & " " & (name of candidateItem as text)
        end try
        try
          set candidate to candidate & " " & (description of candidateItem as text)
        end try
        try
          set candidate to candidate & " " & (help of candidateItem as text)
        end try
        try
          set candidate to candidate & " " & (value of attribute "AXTitle" of candidateItem as text)
        end try
        if candidate contains "Codex" or candidate contains "Claude" or candidate contains "5h" or candidate contains "5ч" then
          return candidate
        end if
      end repeat
    end repeat
    end tell
  end tell
  return ""
end run
OSA
}

wait_for_tray_item() {
  local pid="$1"
  local description=""
  for _ in {1..60}; do
    description="$(tray_item_description "$pid")"
    if [[ -n "${description//[[:space:]]/}" ]]; then
      printf '%s\n' "$description"
      return 0
    fi
    sleep 0.25
  done
  return 1
}

close_front_window() {
  osascript - "$1" >/dev/null <<'OSA'
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    tell (first application process whose unix id is targetPID)
    set frontmost to true
    delay 0.25
    keystroke "w" using command down
    end tell
  end tell
end run
OSA
}

activation_type() {
  local handle
  handle="$(lsappinfo find "pid=$1" 2>/dev/null || true)"
  [[ -n "$handle" ]] || return 1
  lsappinfo info "$handle" 2>/dev/null | sed -n 's/.*type="\([^"]*\)".*/\1/p' | head -n 1
}

wait_for_activation_type() {
  local expected="$1"
  local pid="$2"
  local actual=""
  for _ in {1..60}; do
    actual="$(activation_type "$pid" || true)"
    [[ "$actual" == "$expected" ]] && return 0
    sleep 0.25
  done
  fail "expected activation type $expected, found ${actual:-unknown}"
}

while IFS= read -r pid; do
  kill "$pid" 2>/dev/null || true
done < <(process_pids)
wait_for_process_exit || fail "could not stop the pre-existing $APP_NAME process"

LIMITS_UI_TEST=1 \
LIMITS_TEST_ROOT="$TEMP_DIR/runtime-root" \
LIMITS_DISABLE_EXTERNAL_PROBES=1 \
"$EXPECTED_BINARY" -AppleLanguages '(en)' >"$TEMP_DIR/app.stdout" 2>"$TEMP_DIR/app.stderr" &
LAUNCHED_PID="$!"
[[ "$(wait_for_single_process)" == "$LAUNCHED_PID" ]] || fail "$APP_NAME did not start as the expected process"
COMMAND="$(ps -p "$LAUNCHED_PID" -o command= | sed 's/^ *//')"
[[ "$COMMAND" == "$EXPECTED_BINARY"* ]] || fail "expected binary $EXPECTED_BINARY, got $COMMAND"

wait_for_window_count 1 "$LAUNCHED_PID"
wait_for_activation_type Foreground "$LAUNCHED_PID"
wait_for_tray_item "$LAUNCHED_PID" >/dev/null || fail "menu bar item was not exposed through Accessibility"
echo "foreground state: pid=$LAUNCHED_PID, one window, foreground activation, tray exposed"

close_front_window "$LAUNCHED_PID"
wait_for_window_count 0 "$LAUNCHED_PID"
kill -0 "$LAUNCHED_PID" 2>/dev/null || fail "application terminated after its last window closed"
[[ -n "$(wait_for_tray_item "$LAUNCHED_PID")" ]] || fail "menu bar item disappeared in tray-only state"
echo "tray-only state: same process alive, no presented window, tray exposed"

/usr/bin/open -a "$APP_BUNDLE" 'limits://open'
[[ "$(wait_for_single_process)" == "$LAUNCHED_PID" ]] || fail "URL reopen created a second process"
wait_for_window_count 1 "$LAUNCHED_PID"
wait_for_activation_type Foreground "$LAUNCHED_PID"
echo "URL reopen: same process returned to one foreground-capable window"

close_front_window "$LAUNCHED_PID"
wait_for_window_count 0 "$LAUNCHED_PID"
echo "runtime verification passed"
