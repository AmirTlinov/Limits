# Releasing Limits

`Limits.xcodeproj` is the only owner of the shipped app. A release is complete only when the Developer ID archive is notarized, stapled, uploaded to GitHub Releases, and its EdDSA-signed entry is live in the public Sparkle appcast.

## One-time GitHub configuration

The repository uses these Actions secrets:

| Secret | Contents |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64-encoded Developer ID Application identity and private key in PKCS#12 format |
| `DEVELOPER_ID_P12_PASSWORD` | Password used when exporting that PKCS#12 file |
| `NOTARY_KEY_P8_BASE64` | Base64-encoded App Store Connect API private key |
| `NOTARY_KEY_ID` | App Store Connect API key ID |
| `NOTARY_ISSUER_ID` | App Store Connect API issuer ID |
| `SPARKLE_PRIVATE_KEY` | Private EdDSA key exported by Sparkle `generate_keys` |

The matching Sparkle public key is committed as `SUPublicEDKey` in `Config/Limits-Info.plist`. The private key stays in the macOS Keychain and GitHub Actions secret; it never belongs in git or release artifacts.

GitHub Pages publishes the `gh-pages` branch at <https://amirtlinov.github.io/Limits/>. The release workflow preserves the current feed, inserts the new signed update, and pushes the resulting `appcast.xml` back to that branch.

## Local proof before tagging

```bash
xcodebuild -project Limits.xcodeproj -scheme Limits \
  -destination 'platform=macOS,arch=arm64' test

./script/package_release.sh 1.0.0 --no-notarize
./script/generate_appcast.sh 1.0.0 --existing-appcast site/appcast.xml
```

The packaging script requires the `Developer ID Application` identity for team `M94V58FCVP`. Add `--notarize` after storing a working `LimitsNotary` profile, or provide the App Store Connect API environment documented by `./script/package_release.sh --help`.

## Publish

Create and push an annotated tag from the reviewed release commit:

```bash
git tag -a v1.0.0 -m "Limits 1.0.0"
git push origin v1.0.0
```

The `Release` workflow selects Xcode 26.4.1 on an Apple-silicon macOS 26 runner, imports the Developer ID identity, archives the app, notarizes and staples it, publishes the zip and checksum, signs the Sparkle appcast, creates the GitHub release, and updates GitHub Pages.

The release is accepted only after all three public receipts agree:

```text
GitHub Release zip  -> notarized Limits.app
Sparkle appcast     -> same version, URL, byte length, EdDSA signature
GitHub Pages        -> live appcast.xml containing that release
```
