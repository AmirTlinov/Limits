# Limits

Native macOS tray app for people who switch between several **Codex CLI** and **Claude Code** accounts and want to see remaining limits at a glance.

Limits keeps the important thing close: current account, remaining 5-hour limit, weekly limit, and quick switching between saved accounts.

<p align="center">
  <img src="docs/images/limits-window.png" alt="Limits main window with sanitized demo accounts" width="820">
</p>

<p align="center">
  <img src="docs/images/limits-tray.png" alt="Limits menu bar panel with sanitized demo accounts" width="760">
</p>

> Screenshots use fake `example.com` accounts. They are staged demo scenes, not a real local desktop or private data.

## What it does

- Shows Codex CLI limits in the menu bar panel, native macOS window, and WidgetKit widgets.
- Shows Claude Code live limits when the Claude statusline bridge is enabled.
- Publishes a safe widget snapshot through the macOS App Group container; widgets never read auth files or Keychain credentials.
- Saves separate Codex and Claude accounts for quick switching.
- Highlights providers consistently: Codex is blue, Claude is coral.
- Stores saved auth snapshots in macOS Keychain.

## Install

Download the latest macOS build from **Releases**:

<https://github.com/AmirTlinov/Limits/releases/latest>

Unzip `Limits-...-macOS-arm64.zip`, move `Limits.app` to `/Applications`, then open it. After first launch, add the **Limits** widget from macOS widget gallery if you want limits on the desktop or Notification Center.

The app is Developer ID signed. Widget Gallery discovery requires the shipped app to be Apple-notarized; if macOS reports `source=Unnotarized Developer ID`, the app may launch but the widget extension can stay invisible.

## Notes

- Codex support works through the local Codex CLI auth file and official CLI account/limit surfaces.
- Claude Code supports account switching through Keychain credentials and reads live limits only from Claude Code statusline data.
- The app does not invent Claude limits when Claude Code does not provide them.

## Build locally

```bash
xcodebuild -project Limits.xcodeproj -scheme Limits \
  -destination 'platform=macOS,arch=arm64' test
./script/build_and_run.sh
```

Limits targets macOS 26 on Apple silicon. `Limits.xcodeproj` owns the app, shared framework, widget extension, unit tests, and UI tests.

The packaged app and zip are written to `dist/` by the release command:

```bash
./script/package_release.sh 1.0.0
```

For a widget-visible distribution build, store Apple notary credentials once and package with notarization:

```bash
./script/store_notary_credentials.sh LimitsNotary
./script/package_release.sh 1.0.0 --notarize
```

When prompted, enter the Apple ID email for the developer account, not the Team ID. The notarized path submits a temporary zip, staples the ticket onto `dist/Limits.app`, validates it, then recreates the final release zip.

After installing the notarized app to `/Applications`, verify WidgetKit ingestion:

```bash
./script/verify_widget_extension.sh --refresh-chronod /Applications/Limits.app
```
