#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?Usage: $0 VERSION}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE="Limits-v$VERSION-macOS-arm64.zip"
BASE_URL="https://amirtlinov.github.io/Limits/releases/v$VERSION"
LATEST_URL="https://amirtlinov.github.io/Limits/releases/latest"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/limits-public-release.XXXXXX")"
SPARKLE_ACCOUNT="${LIMITS_SPARKLE_ACCOUNT:-com.amir.Limits}"
TOOLS_DIR="${LIMITS_SPARKLE_TOOLS_DIR:-$ROOT_DIR/.build/SourcePackages/artifacts/sparkle/Sparkle/bin}"
SIGN_UPDATE="$TOOLS_DIR/sign_update"
trap 'rm -rf "$WORK_DIR"' EXIT

download() {
  curl --fail --silent --show-error --location --retry 12 --retry-all-errors --retry-delay 10 "$1" --output "$2"
}

download "$BASE_URL/$ARCHIVE" "$WORK_DIR/$ARCHIVE"
download "$BASE_URL/$ARCHIVE.sha256" "$WORK_DIR/$ARCHIVE.sha256"
download "$BASE_URL/appcast.xml" "$WORK_DIR/appcast.xml"
download "$LATEST_URL/Limits-macOS-arm64.zip" "$WORK_DIR/latest.zip"
download "$LATEST_URL/Limits-macOS-arm64.zip.sha256" "$WORK_DIR/latest.zip.sha256"

LOCAL_SIZE="$(stat -f '%z' "$ROOT_DIR/dist/$ARCHIVE")"
PUBLIC_SIZE="$(stat -f '%z' "$WORK_DIR/$ARCHIVE")"
[[ "$LOCAL_SIZE" == "$PUBLIC_SIZE" ]] || { echo "Public archive byte length differs: $PUBLIC_SIZE != $LOCAL_SIZE" >&2; exit 1; }
cmp "$ROOT_DIR/dist/$ARCHIVE" "$WORK_DIR/$ARCHIVE"
cmp "$ROOT_DIR/dist/appcast.xml" "$WORK_DIR/appcast.xml"
cmp "$WORK_DIR/$ARCHIVE" "$WORK_DIR/latest.zip"
(
  cd "$WORK_DIR"
  shasum -a 256 -c "$ARCHIVE.sha256"
  sed 's/  Limits-macOS-arm64.zip$/  latest.zip/' latest.zip.sha256 | shasum -a 256 -c -
)

xmllint --noout "$WORK_DIR/appcast.xml"
ENCLOSURE_URL="$(xmllint --xpath "string((//*[local-name()='enclosure' and contains(@url, '$ARCHIVE')]/@url)[1])" "$WORK_DIR/appcast.xml")"
ENCLOSURE_LENGTH="$(xmllint --xpath "string((//*[local-name()='enclosure' and contains(@url, '$ARCHIVE')]/@length)[1])" "$WORK_DIR/appcast.xml")"
SIGNATURE="$(xmllint --xpath "string((//*[local-name()='enclosure' and contains(@url, '$ARCHIVE')]/@*[local-name()='edSignature'])[1])" "$WORK_DIR/appcast.xml")"
[[ "$ENCLOSURE_URL" == "$BASE_URL/$ARCHIVE" ]]
[[ "$ENCLOSURE_LENGTH" == "$PUBLIC_SIZE" ]]
[[ -n "$SIGNATURE" ]]

[[ -x "$SIGN_UPDATE" ]] || { echo "Sparkle sign_update tool is unavailable: $SIGN_UPDATE" >&2; exit 1; }
VERIFY_ARGS=(--account "$SPARKLE_ACCOUNT" --verify "$WORK_DIR/$ARCHIVE" "$SIGNATURE")
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  "$SIGN_UPDATE" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" "${VERIFY_ARGS[@]}"
elif [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "${VERIFY_ARGS[@]}"
else
  "$SIGN_UPDATE" "${VERIFY_ARGS[@]}"
fi

xcrun stapler validate "$ROOT_DIR/dist/Limits.app"
spctl -a -t exec -vvv "$ROOT_DIR/dist/Limits.app"
codesign --verify --deep --strict --verbose=2 "$ROOT_DIR/dist/Limits.app"

printf 'public release verified: version=%s bytes=%s checksum=ok EdDSA=verified notarization=ok\n' "$VERSION" "$PUBLIC_SIZE"
