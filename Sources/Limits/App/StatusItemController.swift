import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let openAccountsWindow: () -> Void
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var modelCancellable: AnyCancellable?
    private var defaultsCancellable: AnyCancellable?
    private var progressPillView: StatusProgressPillView?

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
            button.isBordered = false
            button.focusRingType = .none
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor.clear.cgColor
            button.image = nil
            button.imagePosition = .noImage
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")

            let progressView = StatusProgressPillView(frame: button.bounds)
            progressView.autoresizingMask = [.width, .height]
            button.subviews
                .filter { $0 is StatusProgressPillView }
                .forEach { $0.removeFromSuperview() }
            button.addSubview(progressView)
            progressPillView = progressView

            button.target = self
            button.action = #selector(togglePopover(_:))
            button.toolTip = "Limits"
            button.setAccessibilityLabel("Лимиты")
        }

        popover.behavior = .transient
        popover.animates = true
        rebuildPopoverContent()
        startObservingModel()
        refreshStatusItemAppearance()
    }

    func openAccountsWindowFromTray() {
        closePopover()
        openAccountsWindow()
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

    private func showPopover(relativeTo button: NSStatusBarButton) {
        refreshStatusItemAppearance()
        rebuildPopoverContent()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func closePopover() {
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

        progressPillView?.title = provider.displayTitle
        progressPillView?.progress = snapshot.remainingProgress ?? 1
        progressPillView?.isProgressKnown = snapshot.remainingProgress != nil
        progressPillView?.remainingPercent = snapshot.remainingPercent

        guard let button = statusItem?.button else {
            return
        }

        if let remainingPercent = snapshot.remainingPercent {
            var tooltip = "\(provider.displayTitle) · 5ч лимит: \(remainingPercent)% осталось"
            if let resetText = snapshot.resetText {
                tooltip += " · \(resetText)"
            }
            button.toolTip = tooltip
            button.setAccessibilityLabel("\(provider.displayTitle), 5 часов, \(remainingPercent)% осталось")
        } else {
            button.toolTip = "\(provider.displayTitle) · 5ч лимит пока без данных"
            button.setAccessibilityLabel("\(provider.displayTitle), 5-часовой лимит пока без данных")
        }
    }

    private func currentTrayStatusProvider() -> TrayStatusProvider {
        let rawFilter = UserDefaults.standard.string(forKey: AccountsSidebarFilter.trayFilterStorageKey)
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
        row.title == "5ч лимит" || row.title.hasPrefix("5ч")
    }
}

private struct FiveHourLimitSnapshot {
    let remainingProgress: Double?
    let remainingPercent: Int?
    let resetText: String?
}

private final class StatusProgressPillView: NSView {
    private var storedProgress: Double = 1

    var title = "Codex" {
        didSet {
            needsDisplay = true
        }
    }

    var progress: Double {
        get { storedProgress }
        set {
            storedProgress = min(max(newValue, 0), 1)
            needsDisplay = true
        }
    }

    var isProgressKnown = false {
        didSet { needsDisplay = true }
    }

    var remainingPercent: Int? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool {
        true
    }

    override var isOpaque: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard bounds.width > 0, bounds.height > 0 else {
            return
        }

        let pillHeight = min(bounds.height - 2, 20)
        let pillRect = NSRect(
            x: bounds.minX,
            y: bounds.midY - pillHeight / 2,
            width: bounds.width,
            height: pillHeight
        )
        let radius = pillHeight / 2
        let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: radius, yRadius: radius)

        trackColor.setFill()
        pillPath.fill()

        let fillWidth = pillRect.width * progress
        if fillWidth > 0 {
            NSGraphicsContext.saveGraphicsState()
            pillPath.addClip()
            fillColor.setFill()
            NSRect(
                x: pillRect.minX,
                y: pillRect.minY,
                width: fillWidth,
                height: pillRect.height
            ).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        borderColor.setStroke()
        pillPath.lineWidth = 1
        pillPath.stroke()

        drawTitle(in: pillRect)
    }

    private var trackColor: NSColor {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let alpha: CGFloat = if reduceTransparency {
            increaseContrast ? 0.34 : 0.26
        } else {
            increaseContrast ? 0.26 : 0.16
        }
        return NSColor.labelColor.withAlphaComponent(alpha)
    }

    private var fillColor: NSColor {
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

    private var borderColor: NSColor {
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        return NSColor.labelColor.withAlphaComponent(increaseContrast ? 0.38 : 0.24)
    }

    private func drawTitle(in rect: NSRect) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = NSSize(width: 0, height: 0)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.2, weight: .semibold),
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
