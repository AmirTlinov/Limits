import AppKit

@MainActor
final class LimitsApplicationDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppRuntimeCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        RuntimeLog.lifecycle.info("application did finish launching bundle=\(Bundle.main.bundlePath, privacy: .public)")
        NSApp.setActivationPolicy(.accessory)
        RuntimeLog.lifecycle.info("activation policy set to accessory")
        installApplicationIcon()

        let coordinator = AppRuntimeCoordinator()
        self.coordinator = coordinator
        coordinator.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.handleReopen(hasVisibleWindows: flag) ?? true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
