import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let openAccountsWindow: () -> Void
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    init(model: AppModel, openAccountsWindow: @escaping () -> Void) {
        self.model = model
        self.openAccountsWindow = openAccountsWindow
        super.init()
    }

    func install() {
        guard statusItem == nil else {
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: 76)
        item.isVisible = true
        statusItem = item

        if let button = item.button {
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.94).cgColor
            button.layer?.cornerRadius = 10
            button.layer?.borderWidth = 1
            button.layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
            button.image = nil
            button.imagePosition = .noImage
            button.title = "Limits"
            button.attributedTitle = NSAttributedString(
                string: "Limits",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12.2, weight: .semibold),
                    .foregroundColor: NSColor.white,
                ]
            )
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.toolTip = "Limits"
            button.setAccessibilityLabel("Лимиты")
        }

        popover.behavior = .transient
        popover.animates = true
        rebuildPopoverContent()
    }

    func openAccountsWindowFromTray() {
        closePopover()
        openAccountsWindow()
    }

    private func rebuildPopoverContent() {
        let content = MenuBarContentView(model: model) { [weak self] in
            self?.openAccountsWindowFromTray()
        }

        let hostingController = NSHostingController(rootView: content)
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 900
        let height = min(760, max(420, visibleHeight - 96))
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 350, height: height)
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: 350, height: height)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover(relativeTo: sender)
        }
    }

    private func showPopover(relativeTo button: NSStatusBarButton) {
        rebuildPopoverContent()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func closePopover() {
        popover.performClose(nil)
    }
}
