#!/usr/bin/env bash

limits_codesign_identity() {
  if [[ -n "${LIMITS_CODESIGN_IDENTITY:-}" ]]; then
    printf '%s\n' "$LIMITS_CODESIGN_IDENTITY"
    return
  fi

  security find-identity -p codesigning -v 2>/dev/null \
    | awk -F '"' '/Developer ID Application:/ { print $2; exit }'
}

limits_sign_app() {
  local app_bundle="$1"
  local identity
  identity="$(limits_codesign_identity)"
  if [[ -z "$identity" ]]; then
    identity="-"
  fi

  codesign --force --options runtime --timestamp=none --sign "$identity" "$app_bundle" >/dev/null
  echo "codesign: $identity"
}
