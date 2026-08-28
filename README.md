# Limits

[![CI](https://github.com/AmirTlinov/Limits/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/AmirTlinov/Limits/actions/workflows/ci.yml)
[![CodeQL](https://github.com/AmirTlinov/Limits/actions/workflows/codeql.yml/badge.svg?branch=main)](https://github.com/AmirTlinov/Limits/actions/workflows/codeql.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-2ea44f.svg)](LICENSE)

Native macOS app for people who switch between several **Codex** and **Claude Code** accounts and want to understand both remaining limits and actual Codex usage.

Limits keeps the important thing close: which account is most likely to run out first, whether it will last until reset, how many tokens and credits were used, the current API-price equivalent, and quick switching between saved accounts.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/limits-window-dark.png">
    <img src="docs/images/limits-window.png" alt="Limits Codex overview with sanitized demo accounts" width="820">
  </picture>
</p>

<p align="center">
  <img src="docs/images/limits-tray.png" alt="Limits menu bar panel with sanitized demo accounts" width="360">
</p>

> Screenshots are captured from an isolated UI-test fixture of the running app. The fixture cannot read production state, auth files, or Keychain credentials.

## What it does

- Opens on one overview of saved-account usage with a shared period for activity, totals, models, trend, projects, and tasks.
- Shows weekly tokens, Codex credits, the current API-price equivalent, subscription cost, model mix, and daily usage.
- Keeps each account's plan, reset windows, quota bars, and usage on one continuous account surface.
- Forecasts “runs out before reset”, “lasts until reset”, “collecting pace”, and stale evidence from observed server limits.
- Shows Codex limits in the menu bar panel, native macOS window, and WidgetKit widgets.
- Shows Claude only when a saved Claude account exists or Claude Code reports a live, stable signed-in identity.
- Publishes a safe widget snapshot through the macOS App Group container; widgets never read auth files or Keychain credentials.
- Saves separate Codex and Claude accounts for quick switching.
- Highlights providers consistently: Codex is blue, Claude is coral.
- Stores saved auth snapshots in macOS Keychain.
- Can launch itself at login and stay tray-only until you open a window.
- Checks a public, EdDSA-signed Sparkle feed for in-place updates.

## Install

Open the canonical [GitHub Releases page](https://github.com/AmirTlinov/Limits/releases/latest) and download the macOS arm64 zip plus its `.sha256` file. Verify the download before opening it:

```bash
shasum -a 256 -c ./*.zip.sha256
```

Unzip `Limits-...-macOS-arm64.zip`, move `Limits.app` to `/Applications`, then open it. After first launch, add the **Limits** widget from macOS widget gallery if you want limits on the desktop or Notification Center.

Published builds are Developer ID signed. The current release workflow also requires Apple notarization and a stapled ticket; earlier releases predate that gate. If a release note says a build is unnotarized, macOS may require manual approval and the widget extension can stay invisible.

## Notes

- Codex account totals come from the official `account/usage/read` app-server surface. Model-level detail is imported from local Codex JSONL as numeric metadata only.
- Limits reads `session_meta`, `turn_context`, cumulative `token_count`, reroute metadata, repository or working-directory identity, and a task label derived from at most the first 96 characters of the first meaningful user-request line.
- It stores the extracted usage and work metadata locally. It does not store full prompts, responses, transcripts, source files, or project contents. [`PRIVACY.md`](PRIVACY.md) lists every local and network data flow.
- Credits use the versioned [Codex pricing](https://learn.chatgpt.com/docs/pricing) table. API equivalent uses current [OpenAI API pricing](https://developers.openai.com/api/docs/pricing); it is a comparison, not an API bill.
- Claude Code supports account switching through Keychain credentials and reads live limits only from Claude Code statusline data.
- The app does not invent Claude limits when Claude Code does not provide them.

## Build locally

Limits requires an Apple-silicon Mac on macOS 26 or newer. Install Xcode 26.4.1 or a compatible newer Xcode and the deterministic project generator dependency:

```bash
gem install xcodeproj -v 1.27.0 --no-document --user-install
```

```bash
./script/ci_gate.sh
./script/build_and_run.sh
```

The local gate builds the app, runs every hostless test, and checks the bundle
without launching UI automation. GitHub Actions adds the same UI and lifecycle
tests in a dedicated macOS session, so testing does not take over the
developer's keyboard, pointer, windows, or menu bar.

Focused model and persistence checks use the hostless `LimitsUnitTests` scheme. It contains no UI-test target, so a narrow test does not start the app or request UI Automation:

```bash
xcodebuild test -project Limits.xcodeproj -scheme LimitsUnitTests -destination 'platform=macOS,arch=arm64' -only-testing:'LimitsTests/accountIdentityShowsEmailOnlyWhenItAddsASecondIdentity()'
```

The remote CI result is the complete delivery gate. Its isolated runner invokes
`./script/ci_gate.sh --isolated-ui`; the ordinary local command remains
non-interactive.

Limits targets macOS 26 on Apple silicon. `AccountsRepository` owns account identities and credential references. `CodexUsageRepository` owns usage history in SQLite. Provider coordinators own authenticated operations and refresh queues. The app target is the UI facade, while `LimitsShared` carries the localized widget contract. `Limits.xcodeproj` owns those frameworks, the app, widget extension, hostless unit tests, and isolated UI tests.

The repository map in [`AGENTS.md`](AGENTS.md) points from each product question to its code owner and verification path. Contributions follow [`CONTRIBUTING.md`](CONTRIBUTING.md); security reports use the private path in [`SECURITY.md`](SECURITY.md).

The release zip and checksum are written to `dist/` by the release command. The
temporary app bundle stays under Spotlight-hidden `.build/release/package/`:

```bash
./script/package_release.sh 1.0.0
```

This path uses the Xcode archive as the only bundle owner, embeds the real WidgetKit extension and Sparkle framework, Developer ID signs every nested executable with a secure timestamp, then verifies the complete bundle before creating the zip.

For a widget-visible distribution build, store Apple notary credentials once and package with notarization:

```bash
./script/store_notary_credentials.sh LimitsNotary
./script/package_release.sh 1.0.0 --notarize
```

When prompted, enter the Apple ID email for the developer account, not the Team ID. The notarized path submits a temporary zip, staples the ticket onto the staged app, validates it, then creates the final release zip.

After installing the notarized app to `/Applications`, verify WidgetKit ingestion:

```bash
./script/verify_widget_extension.sh --refresh-chronod /Applications/Limits.app
```

Sparkle reads its signed feed from <https://amirtlinov.github.io/Limits/appcast.xml>. Maintainer release steps and required GitHub secrets are documented in [`docs/RELEASING.md`](docs/RELEASING.md).

## License and trademarks

Limits is available under the [MIT License](LICENSE). Embedded dependency notices are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) and are also shipped inside the app bundle.

Limits is an independent project and is not affiliated with, sponsored by, or endorsed by OpenAI or Anthropic. OpenAI, ChatGPT, Codex, Anthropic, and Claude are trademarks of their respective owners.
