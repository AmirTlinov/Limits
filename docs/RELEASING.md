# Releasing Limits

`Limits.xcodeproj` is the owner of the shipped app. A release is complete when the full gate passes, the Developer ID archive is notarized and stapled, and the zip, checksum, release appcast, and root Sparkle feed are public on GitHub Pages.

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

GitHub Pages publishes the `gh-pages` branch at <https://amirtlinov.github.io/Limits/>. Immutable artifacts live under `releases/v1.0.0/`; `releases/latest/` mirrors the newest build. Published version directories remain available because existing appcasts can refer to them. The source repository, GitHub Releases, and Pages download channel are public.

## Local proof before tagging

```bash
./script/ci_gate.sh

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

The `Release` workflow checks out the exact tagged commit, repeats `ci_gate.sh`, imports the Developer ID identity, archives the app, notarizes and staples it, signs the Sparkle appcast, updates the GitHub release, and publishes the public binary channel on GitHub Pages. A manual dispatch also requires an existing annotated tag and builds that tag rather than the current branch head.

The release is accepted only after all public receipts agree:

```text
Pages version URL   -> exact notarized zip and checksum
Sparkle appcast     -> same immutable URL, byte length, and EdDSA signature
Pages latest URL    -> byte-identical newest zip
Apple receipts      -> Developer ID signature and stapled notarization ticket
Sparkle path        -> an isolated copy of the previous signed app upgrades to the new version
```
