import AppKit

@MainActor
final class AppRuntimeCoordinator {
    let model: AppModel
    private let statusItemController: StatusItemController
    private let accountsWindowController: AccountsWindowController
    private var didStart = false

    init() {
        let model = AppModel()
        let accountsWindowController = AccountsWindowController(model: model)

        self.model = model
        self.accountsWindowController = accountsWindowController
        self.statusItemController = StatusItemController(model: model) { [weak accountsWindowController] in
            accountsWindowController?.show()
        }
    }

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

    func handleReopen(hasVisibleWindows: Bool) -> Bool {
        RuntimeLog.lifecycle.info("application reopen hasVisibleWindows=\(hasVisibleWindows, privacy: .public) trackedWindowVisible=\(self.accountsWindowController.hasVisibleWindow, privacy: .public)")
        if !hasVisibleWindows || !accountsWindowController.hasVisibleWindow {
            openAccountsWindow()
        }
        return true
    }
}
