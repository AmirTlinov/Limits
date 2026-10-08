# Releasing Limits

`Limits.xcodeproj` owns the shipped app. Native checks, signing, notarization, and packaging run on the maintainer's local Mac. A release is complete when the notarized zip, checksum, release appcast, and root Sparkle feed are public and the upgrade from the previous signed build succeeds.

## Local setup

The packaging script requires a `Developer ID Application` identity for team `M94V58FCVP`. Store a working `LimitsNotary` Keychain profile with `./script/store_notary_credentials.sh`, or use the App Store Connect API environment documented by `./script/package_release.sh --help`.

Sparkle signing uses the local Keychain account `com.amir.Limits` by default. The matching public key is committed as `SUPublicEDKey` in `Config/Limits-Info.plist`. Private Apple and Sparkle keys stay outside git and release artifacts.

GitHub Pages publishes `gh-pages` at <https://amirtlinov.github.io/Limits/>. The Linux `Publish site` workflow updates the site shell and preserves release artifacts. Version directories remain available because existing appcasts can refer to them; `releases/latest/` mirrors the newest build.

## Prepare the reviewed commit

```bash
VERSION=1.0.1

./script/ci_gate.sh
./script/package_release.sh "$VERSION" --notarize
curl --fail --silent --show-error --location \
  https://amirtlinov.github.io/Limits/appcast.xml \
  --output .build/current-appcast.xml
./script/generate_appcast.sh "$VERSION" --existing-appcast .build/current-appcast.xml
```

The ordinary gate builds, runs hostless tests, and verifies the bundle without launching UI automation. UI, lifecycle, and screenshot checks require a separate local macOS login session; run `LIMITS_ISOLATED_UI_SESSION=1 ./script/ci_gate.sh --isolated-ui` only there.

## Publish the local artifacts

Create the annotated tag and GitHub release from the same reviewed commit:

```bash
git tag -a "v$VERSION" -m "Limits $VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" \
  "dist/Limits-v$VERSION-macOS-arm64.zip" \
  "dist/Limits-v$VERSION-macOS-arm64.zip.sha256" \
  dist/appcast.xml --title "Limits $VERSION" --generate-notes
```

Publish the exact signed files to the existing Pages branch:

```bash
LIMITS_PAGES_DIR="$(mktemp -d)"
gh repo clone AmirTlinov/Limits "$LIMITS_PAGES_DIR" -- --branch gh-pages --single-branch
LIMITS_VERSION_DIR="$LIMITS_PAGES_DIR/releases/v$VERSION"
LIMITS_LATEST_DIR="$LIMITS_PAGES_DIR/releases/latest"
mkdir -p "$LIMITS_VERSION_DIR"
cp dist/appcast.xml "$LIMITS_PAGES_DIR/appcast.xml"
cp dist/appcast.xml "dist/Limits-v$VERSION-macOS-arm64.zip" \
  "dist/Limits-v$VERSION-macOS-arm64.zip.sha256" "$LIMITS_VERSION_DIR/"
if [[ -f "release-notes/v$VERSION.md" ]]; then
  cp "release-notes/v$VERSION.md" "$LIMITS_VERSION_DIR/release-notes.md"
fi
rm -rf "$LIMITS_LATEST_DIR"
mkdir -p "$LIMITS_LATEST_DIR"
cp "$LIMITS_VERSION_DIR"/* "$LIMITS_LATEST_DIR/"
cp "dist/Limits-v$VERSION-macOS-arm64.zip" "$LIMITS_LATEST_DIR/Limits-macOS-arm64.zip"
(cd "$LIMITS_LATEST_DIR" && shasum -a 256 Limits-macOS-arm64.zip > Limits-macOS-arm64.zip.sha256)
git -C "$LIMITS_PAGES_DIR" add appcast.xml releases
git -C "$LIMITS_PAGES_DIR" commit -m "release: publish Limits $VERSION appcast"
git -C "$LIMITS_PAGES_DIR" push origin gh-pages
```

After Pages updates, run `./script/verify_public_release.sh "$VERSION"`. Use `./script/select_previous_release.py "v$VERSION"` with the GitHub releases API to select the newest earlier release containing a signed archive. Download that archive and run `./script/verify_sparkle_update.sh "$VERSION" /path/to/previous.zip` in the separate local session.

Acceptance requires these receipts:

```text
Pages version URL   -> exact notarized zip and checksum
Sparkle appcast     -> same immutable URL, byte length, and EdDSA signature
Pages latest URL    -> byte-identical newest zip
Apple receipts      -> Developer ID signature and stapled notarization ticket
Sparkle path        -> an isolated copy of the previous signed app upgrades to the new version
```
