#!/usr/bin/env bash
set -euo pipefail

PROFILE="${1:-${LIMITS_NOTARY_PROFILE:-LimitsNotary}}"
TEAM_ID="${LIMITS_NOTARY_TEAM_ID:-${LIMITS_APP_GROUP_TEAM_ID:-M94V58FCVP}}"

ARGS=("$PROFILE" --team-id "$TEAM_ID")

if [[ -n "${LIMITS_NOTARY_APPLE_ID:-}" ]]; then
  ARGS+=(--apple-id "$LIMITS_NOTARY_APPLE_ID")
fi

if [[ -n "${LIMITS_NOTARY_PASSWORD:-}" ]]; then
  ARGS+=(--password "$LIMITS_NOTARY_PASSWORD")
fi

if [[ -n "${LIMITS_NOTARY_KEY:-}" || -n "${LIMITS_NOTARY_KEY_ID:-}" || -n "${LIMITS_NOTARY_ISSUER:-}" ]]; then
  if [[ -z "${LIMITS_NOTARY_KEY:-}" || -z "${LIMITS_NOTARY_KEY_ID:-}" || -z "${LIMITS_NOTARY_ISSUER:-}" ]]; then
    echo "set LIMITS_NOTARY_KEY, LIMITS_NOTARY_KEY_ID, and LIMITS_NOTARY_ISSUER together" >&2
    exit 1
  fi
  ARGS=("$PROFILE" --key "$LIMITS_NOTARY_KEY" --key-id "$LIMITS_NOTARY_KEY_ID" --issuer "$LIMITS_NOTARY_ISSUER")
fi

echo "notarytool: storing credentials in keychain profile '$PROFILE' for team '$TEAM_ID'"
xcrun notarytool store-credentials "${ARGS[@]}"
