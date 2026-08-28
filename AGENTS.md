# Project map

`Limits.xcodeproj` is the shipped application owner. Follow the shortest path from a question to the code that performs the behavior and the test that proves it.

```text
Limits/
|-- Sources/Limits/                    # App lifecycle, windows, menu-bar UI, Settings, and update controller.
|-- Sources/LimitsCore/                # Account, credential, usage, persistence, pricing, and provider mechanisms.
|   |-- Models/                        # Value contracts and presentation policies shared by app surfaces.
|   `-- Services/                      # File, Keychain, process, database, and provider behavior owners.
|-- Sources/LimitsShared/              # Localization, progress bars, and the app-to-widget snapshot contract.
|-- Sources/LimitsWidgetExtension/     # Sandboxed WidgetKit reader and widget presentation.
|-- Tests/LimitsTests/                 # Hostless model, persistence, transaction, and service contracts.
|-- Tests/LimitsUITests/               # Isolated app, window, tray, and documentation screenshot contracts.
|-- Config/                            # App and widget plist and entitlement inputs.
|-- script/generate_xcode_project.rb   # Deterministic owner of the generated Xcode project.
|-- script/ci_gate.sh                  # Non-interactive local gate; isolated UI mode belongs to CI.
|-- script/require_isolated_ui_session.sh # Guard against UI automation in a human login session.
|-- script/package_release.sh          # Signed archive, nested bundle verification, notarization, and zip owner.
|-- docs/RELEASING.md                  # Maintainer release contract and public receipts.
|-- PRIVACY.md                         # Exact local data and network behavior disclosed to users.
|-- SECURITY.md                        # Private vulnerability-reporting path and sensitive owners.
`-- site/                              # Static public project page copied to the gh-pages branch.
```

Account identity and credential references belong to `AccountsRepository`; credential bytes belong to `KeychainAuthVault`. Global credential replacement belongs to the provider transaction, which must validate the new identity and restore the previous one on failure. Usage history belongs to `CodexUsageRepository`; rollout parsing extracts only the fields disclosed in `PRIVACY.md`. The widget reads only the immutable App Group snapshot owned by `LimitsWidgetSnapshotPublisher` and `LimitsWidgetSnapshotStore`.

Run the narrowest relevant hostless test while iterating. `./script/ci_gate.sh` is the complete local gate and never launches the app or UI automation. App lifecycle, UI, generated project, resource, entitlement, and release-bundle changes also require the GitHub Actions CI result, which runs `./script/ci_gate.sh --isolated-ui` in a dedicated macOS session. Never set `LIMITS_ISOLATED_UI_SESSION=1` in the developer's active login session.
