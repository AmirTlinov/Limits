import AppKit
import SwiftUI

@MainActor
final class LimitsAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var statusItemController: StatusItemController?
    private var accountsWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        let controller = StatusItemController(model: model) { [weak self] in
            self?.openAccountsWindow()
        }
        statusItemController = controller
        controller.install()
        openAccountsWindow()
    }

    func openAccountsWindow() {
        if let window = accountsWindowController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: AccountsWindowView(model: model))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Лимиты"
        window.setContentSize(NSSize(width: 980, height: 620))
        window.minSize = NSSize(width: 980, height: 620)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.center()

        let controller = NSWindowController(window: window)
        accountsWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard
            let closedWindow = notification.object as? NSWindow,
            closedWindow === accountsWindowController?.window
        else {
            return
        }

        accountsWindowController = nil
    }
}

@main
struct LimitsApp: App {
    @NSApplicationDelegateAdaptor(LimitsAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
