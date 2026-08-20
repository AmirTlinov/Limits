#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
shift || true
[[ -n "$VERSION" ]] || { echo "Usage: $0 VERSION [--existing-appcast PATH]" >&2; exit 2; }
[[ "$VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || { echo "Invalid release version: $VERSION" >&2; exit 2; }

EXISTING_APPCAST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --existing-appcast)
      EXISTING_APPCAST="${2:?--existing-appcast requires a path}"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
ARCHIVE_NAME="Limits-v$VERSION-macOS-arm64.zip"
ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"
OUTPUT_PATH="$DIST_DIR/appcast.xml"
WORK_DIR="$ROOT_DIR/.build/appcast"
SPARKLE_ACCOUNT="${LIMITS_SPARKLE_ACCOUNT:-com.amir.Limits}"
TOOLS_DIR="${LIMITS_SPARKLE_TOOLS_DIR:-$ROOT_DIR/.build/SourcePackages/artifacts/sparkle/Sparkle/bin}"
GENERATE_APPCAST="$TOOLS_DIR/generate_appcast"
SIGN_UPDATE="$TOOLS_DIR/sign_update"

[[ -f "$ARCHIVE_PATH" ]] || { echo "Missing release archive: $ARCHIVE_PATH" >&2; exit 1; }
if [[ ! -x "$GENERATE_APPCAST" ]]; then
  xcodebuild -resolvePackageDependencies \
    -project "$ROOT_DIR/Limits.xcodeproj" \
    -scheme Limits \
    -clonedSourcePackagesDirPath "$ROOT_DIR/.build/SourcePackages" >/dev/null
fi
[[ -x "$GENERATE_APPCAST" ]] || { echo "Sparkle generate_appcast tool was not resolved." >&2; exit 1; }
[[ -x "$SIGN_UPDATE" ]] || { echo "Sparkle sign_update tool was not resolved." >&2; exit 1; }

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$DIST_DIR"
cp "$ARCHIVE_PATH" "$WORK_DIR/$ARCHIVE_NAME"

if [[ -n "$EXISTING_APPCAST" ]]; then
  [[ -f "$EXISTING_APPCAST" ]] || { echo "Missing existing appcast: $EXISTING_APPCAST" >&2; exit 1; }
  cp "$EXISTING_APPCAST" "$WORK_DIR/appcast.xml"
elif [[ -f "$ROOT_DIR/site/appcast.xml" ]]; then
  cp "$ROOT_DIR/site/appcast.xml" "$WORK_DIR/appcast.xml"
fi

RELEASE_NOTES="$DIST_DIR/release-notes-v$VERSION.md"
if [[ ! -f "$RELEASE_NOTES" && -f "$ROOT_DIR/release-notes/v$VERSION.md" ]]; then
  RELEASE_NOTES="$ROOT_DIR/release-notes/v$VERSION.md"
fi
if [[ -f "$RELEASE_NOTES" ]]; then
  cp "$RELEASE_NOTES" "$WORK_DIR/${ARCHIVE_NAME%.zip}.md"
fi

ARGS=(
  --account "$SPARKLE_ACCOUNT"
  --download-url-prefix "https://amirtlinov.github.io/Limits/releases/v$VERSION/"
  --release-notes-url-prefix "https://amirtlinov.github.io/Limits/releases/v$VERSION/"
  --link "https://amirtlinov.github.io/Limits/releases/latest/"
  --embed-release-notes
  --maximum-versions 10
  --maximum-deltas 0
  -o "$WORK_DIR/appcast.xml"
  "$WORK_DIR"
)

if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  "$GENERATE_APPCAST" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" "${ARGS[@]}"
elif [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$GENERATE_APPCAST" --ed-key-file - "${ARGS[@]}"
else
  "$GENERATE_APPCAST" "${ARGS[@]}"
fi

xmllint --noout "$WORK_DIR/appcast.xml"
grep -F "v$VERSION/$ARCHIVE_NAME" "$WORK_DIR/appcast.xml" >/dev/null
SIGNATURE="$(xmllint --xpath "string((//*[local-name()='enclosure' and contains(@url, '$ARCHIVE_NAME')]/@*[local-name()='edSignature'])[1])" "$WORK_DIR/appcast.xml")"
[[ -n "$SIGNATURE" ]] || { echo "Generated appcast has no EdDSA signature for $ARCHIVE_NAME." >&2; exit 1; }

VERIFY_ARGS=(--account "$SPARKLE_ACCOUNT" --verify "$ARCHIVE_PATH" "$SIGNATURE")
if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  "$SIGN_UPDATE" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" "${VERIFY_ARGS[@]}"
elif [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "${VERIFY_ARGS[@]}"
else
  "$SIGN_UPDATE" "${VERIFY_ARGS[@]}"
fi
echo "Verified Sparkle EdDSA signature for $ARCHIVE_NAME" >&2

cp "$WORK_DIR/appcast.xml" "$OUTPUT_PATH"
printf '%s\n' "$OUTPUT_PATH"
