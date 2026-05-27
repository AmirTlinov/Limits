#!/usr/bin/env bash

limits_codesign_identity() {
  if [[ -n "${LIMITS_CODESIGN_IDENTITY:-}" ]]; then
    printf '%s\n' "$LIMITS_CODESIGN_IDENTITY"
    return
  fi

  security find-identity -p codesigning -v 2>/dev/null \
    | awk -F '"' '/Developer ID Application:/ { print $2; exit }'
}

limits_codesign_team_identifier() {
  local identity="$1"
  sed -n 's/.*(\([A-Z0-9][A-Z0-9]*\)).*/\1/p' <<<"$identity"
}

limits_require_codesign_team() {
  local expected_team_id="$1"
  local identity
  identity="$(limits_codesign_identity)"
  if [[ -z "$identity" || "$identity" == "-" ]]; then
    echo "codesign: a real signing identity is required for App Group $expected_team_id" >&2
    exit 1
  fi

  local actual_team_id
  actual_team_id="$(limits_codesign_team_identifier "$identity")"
  if [[ -n "$expected_team_id" && "$actual_team_id" != "$expected_team_id" ]]; then
    echo "codesign: identity team '$actual_team_id' does not match App Group team '$expected_team_id'" >&2
    echo "codesign: identity: $identity" >&2
    exit 1
  fi
}

limits_sign_path() {
  local path="$1"
  local entitlements="${2:-}"
  local identity
  identity="$(limits_codesign_identity)"
  if [[ -z "$identity" ]]; then
    identity="-"
  fi

  local args=(--force --options runtime --timestamp=none --sign "$identity")
  if [[ -n "$entitlements" ]]; then
    args+=(--entitlements "$entitlements")
  fi
  args+=("$path")

  codesign "${args[@]}" >/dev/null
  echo "codesign: $identity $path"
}

limits_sign_app() {
  limits_sign_path "$@"
}
