# Contributing to Limits

Limits accepts focused bug fixes and improvements through pull requests. Start with an issue when a change alters credential handling, persisted data, the update channel, or a visible product contract.

## Development setup

You need an Apple-silicon Mac running macOS 26 or newer, Xcode 26.4.1 or a compatible newer Xcode, Ruby, Python 3, and the `xcodeproj` gem pinned by CI:

```bash
gem install xcodeproj -v 1.27.0 --no-document --user-install
./script/ci_gate.sh
```

If Ruby installs executables outside `PATH`, add `$(ruby -e 'print Gem.user_dir')/bin` for the current shell. Xcode resolves the exact Sparkle revision recorded in `Package.resolved`.

The complete gate regenerates the Xcode project, builds the app, runs hostless unit tests, runs isolated UI tests, and verifies the real app lifecycle. It opens and closes a test build of Limits. Use the focused `LimitsUnitTests` scheme while iterating on model or persistence code:

```bash
xcodebuild test \
  -project Limits.xcodeproj \
  -scheme LimitsUnitTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:'LimitsTests/testName'
```

## Change contract

Every pull request should identify the owner of the changed behavior, the observable consequence, and the command that proved it. Keep generated `Limits.xcodeproj` changes in sync by running `./script/generate_xcode_project.rb` after adding or removing source files or resources.

Credential and rollout fixtures must be synthetic. Keep every real `auth.json`, Claude Keychain payload, Codex rollout, account identifier, email address, private Sparkle key, Apple signing key, and notarization credential outside the repository and its logs. A change that reads or stores more local data must update both [`PRIVACY.md`](PRIVACY.md) and the in-app disclosure in Settings.

Use conventional commit subjects such as `fix(accounts): restore previous auth on validation failure`. Release signing and notarization remain maintainer-only operations described in [`docs/RELEASING.md`](docs/RELEASING.md).

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).
