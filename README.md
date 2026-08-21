# Limits

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

- Opens on a Codex overview with the nearest weekly-limit risk across all saved accounts.
- Shows weekly tokens, Codex credits, the current API-price equivalent, subscription cost, model mix, and daily usage.
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

Download the latest public macOS build:

<https://amirtlinov.github.io/Limits/releases/latest/Limits-macOS-arm64.zip>

Unzip `Limits-...-macOS-arm64.zip`, move `Limits.app` to `/Applications`, then open it. After first launch, add the **Limits** widget from macOS widget gallery if you want limits on the desktop or Notification Center.

The app is Developer ID signed. Widget Gallery discovery requires the shipped app to be Apple-notarized; if macOS reports `source=Unnotarized Developer ID`, the app may launch but the widget extension can stay invisible.

## Notes

- Codex account totals come from the official `account/usage/read` app-server surface. Model-level detail is imported from local Codex JSONL as numeric metadata only.
- Limits reads `session_meta`, `turn_context`, cumulative `token_count`, and reroute metadata. It does not store conversation text, prompts, responses, transcripts, or project contents.
- Credits use the versioned [Codex pricing](https://learn.chatgpt.com/docs/pricing) table. API equivalent uses current [OpenAI API pricing](https://developers.openai.com/api/docs/pricing); it is a comparison, not an API bill.
- Claude Code supports account switching through Keychain credentials and reads live limits only from Claude Code statusline data.
- The app does not invent Claude limits when Claude Code does not provide them.

## Build locally

```bash
./script/ci_gate.sh
./script/build_and_run.sh
```

Limits targets macOS 26 on Apple silicon. `AccountsRepository` owns account identities and credential references. `CodexUsageRepository` owns usage history in SQLite. Provider coordinators own authenticated operations and refresh queues. The app target is the UI facade, while `LimitsShared` carries the localized widget contract. `Limits.xcodeproj` owns those frameworks, the app, widget extension, hostless unit tests, and isolated UI tests.

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
