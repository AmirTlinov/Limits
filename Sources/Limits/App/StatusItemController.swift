import AppKit
import Combine
import SwiftUI

struct StatusItemInstallSnapshot: Equatable {
    let isNewInstall: Bool
    let hasStatusItem: Bool
    let hasButton: Bool
    let hasImage: Bool
    let length: CGFloat
    let visibleLabel: String
}

@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let openAccountsWindow: () -> Void
    private let statusItemLength: CGFloat = 84
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var modelCancellable: AnyCancellable?
    private var defaultsCancellable: AnyCancellable?

    init(model: AppModel, openAccountsWindow: @escaping () -> Void) {
        self.model = model
        self.openAccountsWindow = openAccountsWindow
        super.init()
    }

    @discardableResult
    func install() -> StatusItemInstallSnapshot {
        if let item = statusItem {
            RuntimeLog.tray.info("status item install skipped because it already exists")
            return installSnapshot(for: item, isNewInstall: false)
        }

        let item = NSStatusBar.system.statusItem(withLength: statusItemLength)
        item.isVisible = true
        statusItem = item

        if let button = item.button {
            configure(button: button)
        } else {
            RuntimeLog.tray.error("status item button missing after creation")
        }

        popover.behavior = .transient
        popover.animates = true
        rebuildPopoverContent()
        startObservingModel()
        refreshStatusItemAppearance()

        let snapshot = installSnapshot(for: item, isNewInstall: true)
        RuntimeLog.tray.info("status item installed hasButton=\(snapshot.hasButton, privacy: .public) hasImage=\(snapshot.hasImage, privacy: .public) length=\(Double(snapshot.length), privacy: .public) label=\(snapshot.visibleLabel, privacy: .public)")
        return snapshot
    }

    func openAccountsWindowFromTray() {
        closePopover()
        RuntimeLog.tray.info("open accounts window requested from tray")
        openAccountsWindow()
    }

    private func configure(button: NSStatusBarButton) {
        button.isBordered = false
        button.focusRingType = .none
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.toolTip = "Limits"
        button.setAccessibilityLabel(TrayStatusProvider.codex.displayTitle)
        button.setAccessibilityTitle(TrayStatusProvider.codex.displayTitle)
    }

    private func rebuildPopoverContent() {
        let content = MenuBarContentView(
            model: model,
            openAccountsWindow: { [weak self] in
                self?.openAccountsWindowFromTray()
            },
            providerFilterDidChange: { [weak self] _ in
                self?.refreshStatusItemAppearance()
            }
        )

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

    private func showPopover(relativeTo sender: NSStatusBarButton) {
        let button = statusItem?.button ?? sender
        guard button.window != nil else {
            RuntimeLog.tray.error("cannot show tray popover because status button is detached")
            return
        }

        RuntimeLog.tray.info("tray popover opened")
        rebuildPopoverContent()
        button.layoutSubtreeIfNeeded()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        alignPopoverWindow(to: button)
        DispatchQueue.main.async { [weak self, weak button] in
            guard let self, let button else { return }
            self.alignPopoverWindow(to: button)
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    private func alignPopoverWindow(to button: NSStatusBarButton) {
        guard
            let buttonWindow = button.window,
            let popoverWindow = popover.contentViewController?.view.window
        else {
            RuntimeLog.tray.error("cannot align tray popover because windows are missing")
            return
        }

        let anchorInWindow = button.convert(button.bounds, to: nil)
        let anchor = buttonWindow.convertToScreen(anchorInWindow)
        let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchor
        var frame = popoverWindow.frame

        frame.origin.x = anchor.midX - frame.width / 2
        frame.origin.x = min(max(frame.origin.x, screenFrame.minX + 8), screenFrame.maxX - frame.width - 8)
        frame.origin.y = anchor.minY - frame.height - 2
        if frame.origin.y < screenFrame.minY + 8 {
            frame.origin.y = screenFrame.minY + 8
        }

        popoverWindow.setFrame(frame, display: true)
        RuntimeLog.tray.debug("tray popover aligned anchorX=\(anchor.midX, privacy: .public) anchorY=\(anchor.minY, privacy: .public) windowX=\(frame.minX, privacy: .public) windowY=\(frame.minY, privacy: .public)")
    }

    private func closePopover() {
        if popover.isShown {
            RuntimeLog.tray.info("tray popover closed")
        }
        popover.performClose(nil)
    }

    private func startObservingModel() {
        modelCancellable = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.refreshStatusItemAppearance()
            }
        }

        defaultsCancellable = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshStatusItemAppearance()
                }
            }
    }

    private func refreshStatusItemAppearance() {
        let provider = currentTrayStatusProvider()
        let snapshot = currentFiveHourLimitSnapshot(for: provider)
        let tooltip = tooltipText(provider: provider, snapshot: snapshot)

        guard let button = statusItem?.button else {
            RuntimeLog.tray.error("cannot refresh status item because button is missing")
            return
        }

        syncStatusButton(provider: provider, snapshot: snapshot, tooltip: tooltip, on: button)
        RuntimeLog.tray.debug("status item refreshed provider=\(provider.displayTitle, privacy: .public) known=\(snapshot.remainingPercent != nil, privacy: .public)")
    }

    private func syncStatusButton(provider: TrayStatusProvider, snapshot: FiveHourLimitSnapshot, tooltip: String, on button: NSStatusBarButton) {
        let title = provider.displayTitle
        let image = StatusItemPillRenderer.render(
            title: title,
            progress: snapshot.remainingProgress ?? 1,
            isProgressKnown: snapshot.remainingProgress != nil,
            remainingPercent: snapshot.remainingPercent
        )

        statusItem?.length = statusItemLength
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.toolTip = tooltip
        button.setAccessibilityLabel(accessibilityLabel(provider: provider, snapshot: snapshot))
        button.setAccessibilityTitle(title)
        button.needsDisplay = true
    }

    private func tooltipText(provider: TrayStatusProvider, snapshot: FiveHourLimitSnapshot) -> String {
        if let remainingPercent = snapshot.remainingPercent {
            var tooltip = L10n.tr("tray.tooltip.five_hour", provider.displayTitle, remainingPercent)
            if let resetText = snapshot.resetText {
                tooltip += " · \(resetText)"
            }
            return tooltip
        }

        return L10n.tr("tray.tooltip.five_hour.no_data", provider.displayTitle)
    }

    private func accessibilityLabel(provider: TrayStatusProvider, snapshot: FiveHourLimitSnapshot) -> String {
        if let remainingPercent = snapshot.remainingPercent {
            return L10n.tr("tray.accessibility.five_hour", provider.displayTitle, remainingPercent)
        }

        return L10n.tr("tray.accessibility.five_hour.no_data", provider.displayTitle)
    }

    private func installSnapshot(for item: NSStatusItem, isNewInstall: Bool) -> StatusItemInstallSnapshot {
        let button = item.button
        return StatusItemInstallSnapshot(
            isNewInstall: isNewInstall,
            hasStatusItem: true,
            hasButton: button != nil,
            hasImage: button?.image != nil,
            length: item.length,
            visibleLabel: button?.toolTip ?? button?.title ?? ""
        )
    }

    private func currentTrayStatusProvider() -> TrayStatusProvider {
        let rawFilter = UserDefaults.standard.string(forKey: AccountsSidebarFilter.providerFilterStorageKey)
        let filter = rawFilter.flatMap(AccountsSidebarFilter.init(rawValue:)) ?? .all
        return filter.trayStatusProvider
    }

    private func currentFiveHourLimitSnapshot(for provider: TrayStatusProvider) -> FiveHourLimitSnapshot {
        let sections: [RateLimitDisplaySection] = switch provider {
        case .codex:
            model.currentCLIRateLimitSections()
        case .claude:
            model.currentClaudeLiveRateLimitSections()
        }

        let row = sections
            .flatMap(\.rows)
            .first(where: isFiveHourLimitRow)

        guard let row else {
            return FiveHourLimitSnapshot(remainingProgress: nil, remainingPercent: nil, resetText: nil)
        }

        return FiveHourLimitSnapshot(
            remainingProgress: row.remainingProgressValue,
            remainingPercent: row.remainingPercent,
            resetText: row.resetText
        )
    }

    private func isFiveHourLimitRow(_ row: RateLimitDisplayRow) -> Bool {
        row.title == L10n.tr("limit.five_hour") || row.id.contains("five_hour")
    }
}

private struct FiveHourLimitSnapshot {
    let remainingProgress: Double?
    let remainingPercent: Int?
    let resetText: String?
}

private enum StatusItemPillRenderer {
    static func render(title: String, progress: Double, isProgressKnown: Bool, remainingPercent: Int?) -> NSImage {
        let font = NSFont.systemFont(ofSize: 12.2, weight: .semibold)
        let textSize = (title as NSString).size(withAttributes: [.font: font])
        let width = max(64, min(76, ceil(textSize.width + 28)))
        let height: CGFloat = 22
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.isTemplate = false

        image.lockFocus()
        defer { image.unlockFocus() }

        let pillRect = NSRect(x: 1, y: 1, width: width - 2, height: height - 2)
        let radius = pillRect.height / 2
        let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: radius, yRadius: radius)

        trackColor.setFill()
        pillPath.fill()

        let clampedProgress = min(max(progress, 0), 1)
        let fillWidth = pillRect.width * clampedProgress
        if fillWidth > 0 {
            NSGraphicsContext.saveGraphicsState()
            pillPath.addClip()
            fillColor(isProgressKnown: isProgressKnown, remainingPercent: remainingPercent).setFill()
            NSRect(x: pillRect.minX, y: pillRect.minY, width: fillWidth, height: pillRect.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        borderColor.setStroke()
        pillPath.lineWidth = 1
        pillPath.stroke()
        draw(title: title, font: font, in: pillRect)

        return image
    }

    private static var trackColor: NSColor {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let alpha: CGFloat = if reduceTransparency {
            increaseContrast ? 0.34 : 0.26
        } else {
            increaseContrast ? 0.26 : 0.16
        }
        return NSColor.labelColor.withAlphaComponent(alpha)
    }

    private static func fillColor(isProgressKnown: Bool, remainingPercent: Int?) -> NSColor {
        guard isProgressKnown, let remainingPercent else {
            return NSColor.systemBlue.withAlphaComponent(0.72)
        }

        switch remainingPercent {
        case ...9:
            return NSColor.systemRed.withAlphaComponent(0.94)
        case 10...24:
            return NSColor.systemOrange.withAlphaComponent(0.94)
        default:
            return NSColor.systemBlue.withAlphaComponent(0.94)
        }
    }

    private static var borderColor: NSColor {
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        return NSColor.labelColor.withAlphaComponent(increaseContrast ? 0.38 : 0.24)
    }

    private static func draw(title: String, font: NSFont, in rect: NSRect) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = NSSize(width: 0, height: 0)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle,
            .shadow: shadow,
        ]

        let text = title as NSString
        let textSize = text.size(withAttributes: attributes)
        let textRect = NSRect(
            x: rect.minX,
            y: rect.midY - textSize.height / 2 - 0.5,
            width: rect.width,
            height: textSize.height + 1
        )

        text.draw(in: textRect, withAttributes: attributes)
    }
}
