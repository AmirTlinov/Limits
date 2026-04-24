import AppKit
import SwiftUI

@MainActor
final class AccountsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var windowController: NSWindowController?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    var hasVisibleWindow: Bool {
        windowController?.window?.isVisible == true
    }

    func show() {
        if let window = windowController?.window {
            RuntimeLog.window.info("accounts window reused visible=\(window.isVisible, privacy: .public)")
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: AccountsWindowView(model: model))
        let window = NSWindow(contentViewController: hostingController)
        window.title = L10n.tr("app.title")
        window.setContentSize(NSSize(width: 980, height: 620))
        window.minSize = NSSize(width: 980, height: 620)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        RuntimeLog.window.info("accounts window opened")
    }

    func windowWillClose(_ notification: Notification) {
        guard
            let closedWindow = notification.object as? NSWindow,
            closedWindow === windowController?.window
        else {
            return
        }

        windowController = nil
        RuntimeLog.window.info("accounts window closed")
    }
}
