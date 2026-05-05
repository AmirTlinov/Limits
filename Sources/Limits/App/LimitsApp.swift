import AppKit

@MainActor
final class LimitsApplicationDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppRuntimeCoordinator?
    private var languageObserver: NSObjectProtocol?
    private var keyboardShortcutMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        RuntimeLog.lifecycle.info("application did finish launching bundle=\(Bundle.main.bundlePath, privacy: .public)")
        NSApp.setActivationPolicy(.accessory)
        RuntimeLog.lifecycle.info("activation policy set to accessory")
        installApplicationIcon()

        let coordinator = AppRuntimeCoordinator()
        self.coordinator = coordinator
        installApplicationMenu()
        installKeyboardShortcuts()
        languageObserver = NotificationCenter.default.addObserver(forName: L10n.languageDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.installApplicationMenu()
            }
        }
        coordinator.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.handleReopen(hasVisibleWindows: flag) ?? true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func openAccountsFromMenu() {
        coordinator?.openAccountsWindow()
    }

    @objc private func openSettingsFromMenu() {
        coordinator?.openSettingsWindow()
    }

    @objc private func closeWindowFromMenu(_: Any?) {
        coordinator?.closeFrontmostWindow()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(closeWindowFromMenu(_:)) {
            return coordinator?.hasVisibleWindow == true
        }

        return true
    }

    private func installKeyboardShortcuts() {
        keyboardShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let shortcutFlags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let isCloseWindowKey = event.charactersIgnoringModifiers?.lowercased() == "w" || event.keyCode == 13
            guard shortcutFlags == .command, isCloseWindowKey, self?.coordinator?.hasVisibleWindow == true else {
                return event
            }

            self?.coordinator?.closeFrontmostWindow()
            return nil
        }
    }

    private func installApplicationIcon() {
        guard
            let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        else {
            RuntimeLog.lifecycle.warning("application icon not found in bundle resources")
            return
        }

        NSApp.applicationIconImage = icon
        RuntimeLog.lifecycle.info("application icon installed")
    }

    private func installApplicationMenu() {
        let mainMenu = NSMenu(title: "MainMenu")

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu(title: L10n.tr("app.title"))
        appMenuItem.submenu = appMenu

        let settingsItem = NSMenuItem(
            title: L10n.tr("action.settings"),
            action: #selector(openSettingsFromMenu),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: L10n.tr("action.quit"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)

        let windowMenu = NSMenu(title: L10n.tr("action.open_window"))
        windowMenuItem.submenu = windowMenu

        let closeWindowItem = NSMenuItem(
            title: L10n.tr("action.close_window"),
            action: #selector(closeWindowFromMenu(_:)),
            keyEquivalent: "w"
        )
        closeWindowItem.target = self
        windowMenu.addItem(closeWindowItem)
        windowMenu.addItem(.separator())

        let accountsItem = NSMenuItem(
            title: L10n.tr("action.open_window"),
            action: #selector(openAccountsFromMenu),
            keyEquivalent: "0"
        )
        accountsItem.target = self
        windowMenu.addItem(accountsItem)

        NSApp.mainMenu = mainMenu
        RuntimeLog.lifecycle.info("application menu installed")
    }
}

@main
enum LimitsApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = LimitsApplicationDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        RuntimeLog.lifecycle.info("application run loop starting")
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
