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

        let item = NSStatusBar.system.statusItem(withLength: 30)
        statusItem = item

        if let button = item.button {
            button.image = Self.statusBarImage()
            button.imagePosition = .imageOnly
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

    private static func statusBarImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer {
            image.unlockFocus()
            image.isTemplate = true
        }

        NSColor.black.setStroke()
        NSColor.black.setFill()

        let outer = NSBezierPath(ovalIn: NSRect(x: 2.5, y: 2.5, width: 13, height: 13))
        outer.lineWidth = 1.8
        outer.stroke()

        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: CGPoint(x: 9, y: 8.5),
            radius: 4.5,
            startAngle: 205,
            endAngle: 335
        )
        arc.lineWidth = 1.6
        arc.stroke()

        let needle = NSBezierPath()
        needle.move(to: CGPoint(x: 9, y: 8.5))
        needle.line(to: CGPoint(x: 12.4, y: 11.5))
        needle.lineWidth = 1.8
        needle.stroke()

        NSBezierPath(ovalIn: NSRect(x: 7.6, y: 7.1, width: 2.8, height: 2.8)).fill()

        return image
    }
}
