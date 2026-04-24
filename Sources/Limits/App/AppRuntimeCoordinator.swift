import AppKit

@MainActor
final class AppRuntimeCoordinator {
    let model = AppModel()
    private var didStart = false

    private lazy var accountsWindowController = AccountsWindowController(
        model: model,
        windowVisibilityDidChange: { [weak self] in
            self?.syncActivationPolicyWithVisibleWindows()
        }
    )

    private lazy var settingsWindowController = SettingsWindowController(
        languageDidChange: { [weak self] in
            self?.handleLanguageDidChange()
        },
        windowVisibilityDidChange: { [weak self] in
            self?.syncActivationPolicyWithVisibleWindows()
        }
    )

    private lazy var statusItemController = StatusItemController(
        model: model,
        openAccountsWindow: { [weak self] in
            self?.openAccountsWindow()
        },
        openSettingsWindow: { [weak self] in
            self?.openSettingsWindow()
        }
    )

    func start() {
        guard !didStart else {
            RuntimeLog.lifecycle.info("coordinator start ignored because it already started")
            return
        }

        didStart = true
        RuntimeLog.lifecycle.info("coordinator start")
        let snapshot = statusItemController.install()
        RuntimeLog.lifecycle.info("status item install snapshot hasButton=\(snapshot.hasButton, privacy: .public) hasImage=\(snapshot.hasImage, privacy: .public) label=\(snapshot.visibleLabel, privacy: .public)")

        DispatchQueue.main.async { [weak self] in
            self?.openAccountsWindow()
        }
    }

    func openAccountsWindow() {
        accountsWindowController.show()
    }

    func openSettingsWindow() {
        settingsWindowController.show()
    }

    func handleReopen(hasVisibleWindows: Bool) -> Bool {
        RuntimeLog.lifecycle.info("application reopen hasVisibleWindows=\(hasVisibleWindows, privacy: .public) trackedWindowVisible=\(self.accountsWindowController.hasVisibleWindow, privacy: .public)")
        if !hasVisibleWindows || !accountsWindowController.hasVisibleWindow {
            openAccountsWindow()
        }
        return true
    }

    private func handleLanguageDidChange() {
        model.invalidateLocalizedText()
        accountsWindowController.refreshLocalizedText()
        settingsWindowController.refreshLocalizedText()
        statusItemController.refreshLocalizedText()
    }

    private func syncActivationPolicyWithVisibleWindows() {
        let shouldShowInDock = accountsWindowController.hasVisibleWindow || settingsWindowController.hasVisibleWindow
        if shouldShowInDock {
            NSApp.setActivationPolicy(.regular)
            RuntimeLog.lifecycle.info("activation policy set to regular because a GUI window is visible")
        } else {
            NSApp.setActivationPolicy(.accessory)
            RuntimeLog.lifecycle.info("activation policy set to accessory because no GUI windows are visible")
        }
    }
}
