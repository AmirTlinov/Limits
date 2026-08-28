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
|-- script/ci_gate.sh                  # Complete local and CI delivery gate.
|-- script/package_release.sh          # Signed archive, nested bundle verification, notarization, and zip owner.
|-- docs/RELEASING.md                  # Maintainer release contract and public receipts.
|-- PRIVACY.md                         # Exact local data and network behavior disclosed to users.
|-- SECURITY.md                        # Private vulnerability-reporting path and sensitive owners.
`-- site/                              # Static public project page copied to the gh-pages branch.
```

Account identity and credential references belong to `AccountsRepository`; credential bytes belong to `KeychainAuthVault`. Global credential replacement belongs to the provider transaction, which must validate the new identity and restore the previous one on failure. Usage history belongs to `CodexUsageRepository`; rollout parsing extracts only the fields disclosed in `PRIVACY.md`. The widget reads only the immutable App Group snapshot owned by `LimitsWidgetSnapshotPublisher` and `LimitsWidgetSnapshotStore`.

Run the narrowest relevant hostless test while iterating. Run `./script/ci_gate.sh` whenever a change crosses the app lifecycle, UI, generated project, resource, entitlement, or release-bundle contract.
