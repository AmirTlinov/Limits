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
    private let openSettingsWindow: () -> Void
    private let statusItemLength: CGFloat = 54
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var modelCancellable: AnyCancellable?
    private var defaultsCancellable: AnyCancellable?
    private var languageCancellable: AnyCancellable?

    init(model: AppModel, openAccountsWindow: @escaping () -> Void, openSettingsWindow: @escaping () -> Void) {
        self.model = model
        self.openAccountsWindow = openAccountsWindow
        self.openSettingsWindow = openSettingsWindow
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

    func openSettingsWindowFromTray() {
        closePopover()
        RuntimeLog.tray.info("open settings window requested from tray")
        openSettingsWindow()
    }

    func refreshLocalizedText() {
        rebuildPopoverContent()
        refreshStatusItemAppearance()
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
            openSettingsWindow: { [weak self] in
                self?.openSettingsWindowFromTray()
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

        languageCancellable = NotificationCenter.default.publisher(for: L10n.languageDidChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshLocalizedText()
                }
            }
    }

    private func refreshStatusItemAppearance() {
        let selectedProvider = currentTrayStatusProvider()
        let codexSnapshot = currentFiveHourLimitSnapshot(for: .codex)
        let claudeSnapshot = currentFiveHourLimitSnapshot(for: .claude)
        let tooltip = tooltipText(codexSnapshot: codexSnapshot, claudeSnapshot: claudeSnapshot)

        guard let button = statusItem?.button else {
            RuntimeLog.tray.error("cannot refresh status item because button is missing")
            return
        }

        syncStatusButton(
            selectedProvider: selectedProvider,
            codexSnapshot: codexSnapshot,
            claudeSnapshot: claudeSnapshot,
            tooltip: tooltip,
            on: button
        )
        RuntimeLog.tray.debug("status item refreshed selectedProvider=\(selectedProvider.displayTitle, privacy: .public) codexKnown=\(codexSnapshot.remainingPercent != nil, privacy: .public) claudeKnown=\(claudeSnapshot.remainingPercent != nil, privacy: .public)")
    }

    private func syncStatusButton(
        selectedProvider: TrayStatusProvider,
        codexSnapshot: FiveHourLimitSnapshot,
        claudeSnapshot: FiveHourLimitSnapshot,
        tooltip: String,
        on button: NSStatusBarButton
    ) {
        let codexAccountCount = visibleCodexAccountCount()
        let claudeAccountCount = visibleClaudeAccountCount()
        let image = StatusItemIconRenderer.render(
            codex: ProviderRingSnapshot(snapshot: codexSnapshot),
            claude: ProviderRingSnapshot(snapshot: claudeSnapshot),
            selectedProvider: selectedProvider,
            codexAccountCount: codexAccountCount,
            claudeAccountCount: claudeAccountCount
        )

        statusItem?.length = statusItemLength
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.toolTip = tooltip
        button.setAccessibilityLabel(accessibilityLabel(codexSnapshot: codexSnapshot, claudeSnapshot: claudeSnapshot, codexAccountCount: codexAccountCount, claudeAccountCount: claudeAccountCount))
        button.setAccessibilityTitle("Limits")
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

    private func tooltipText(codexSnapshot: FiveHourLimitSnapshot, claudeSnapshot: FiveHourLimitSnapshot) -> String {
        [
            tooltipText(provider: .codex, snapshot: codexSnapshot),
            tooltipText(provider: .claude, snapshot: claudeSnapshot),
        ].joined(separator: " · ")
    }

    private func accessibilitySegment(provider: TrayStatusProvider, snapshot: FiveHourLimitSnapshot) -> String {
        let base: String = if let remainingPercent = snapshot.remainingPercent {
            L10n.tr("tray.accessibility.five_hour", provider.displayTitle, remainingPercent)
        } else {
            L10n.tr("tray.accessibility.five_hour.no_data", provider.displayTitle)
        }
        return base
    }

    private func accessibilityLabel(
        codexSnapshot: FiveHourLimitSnapshot,
        claudeSnapshot: FiveHourLimitSnapshot,
        codexAccountCount: Int,
        claudeAccountCount: Int
    ) -> String {
        var parts = [
            accessibilitySegment(provider: .codex, snapshot: codexSnapshot),
            accessibilitySegment(provider: .claude, snapshot: claudeSnapshot),
        ]

        if codexAccountCount > 0 {
            parts.append("Codex · \(L10n.accountCount(codexAccountCount))")
        }

        if claudeAccountCount > 0 {
            parts.append("Claude · \(L10n.accountCount(claudeAccountCount))")
        }

        return parts.joined(separator: " · ")
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

    private func visibleCodexAccountCount() -> Int {
        let currentCountsAsAccount: Bool = switch model.currentCLIState.source {
        case .stored, .external:
            true
        case .missing, .unreadable:
            false
        }

        let storedOtherCount = model.accounts.filter { !model.isCurrentCLIAccount($0) }.count
        return (currentCountsAsAccount ? 1 : 0) + storedOtherCount
    }

    private func visibleClaudeAccountCount() -> Int {
        let currentCountsAsAccount: Bool = switch model.currentClaudeState.source {
        case .stored, .external:
            true
        case .loggedOut, .notInstalled, .unreadable:
            false
        }

        let storedOtherCount = model.claudeAccounts.filter { !model.isCurrentClaudeAccount($0) }.count
        return (currentCountsAsAccount ? 1 : 0) + storedOtherCount
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

private struct ProviderRingSnapshot {
    let progress: Double
    let isProgressKnown: Bool
    let remainingPercent: Int?

    init(snapshot: FiveHourLimitSnapshot) {
        self.progress = snapshot.remainingProgress ?? 1
        self.isProgressKnown = snapshot.remainingProgress != nil
        self.remainingPercent = snapshot.remainingPercent
    }
}

private enum StatusItemIconRenderer {
    static func render(
        codex: ProviderRingSnapshot,
        claude: ProviderRingSnapshot,
        selectedProvider: TrayStatusProvider,
        codexAccountCount: Int,
        claudeAccountCount: Int
    ) -> NSImage {
        let size = NSSize(width: 46, height: 22)
        let image = NSImage(size: size)
        image.isTemplate = false

        image.lockFocus()
        defer { image.unlockFocus() }

        drawProviderRing(
            codex,
            center: NSPoint(x: 12, y: size.height / 2),
            accent: .systemBlue,
            isSelected: selectedProvider == .codex,
            centerText: codexAccountCount > 0 ? String(min(codexAccountCount, 9)) : nil
        )
        drawProviderRing(
            claude,
            center: NSPoint(x: 34, y: size.height / 2),
            accent: .systemOrange,
            isSelected: selectedProvider == .claude,
            centerText: claudeAccountCount > 0 ? String(min(claudeAccountCount, 9)) : nil
        )

        return image
    }

    private static func drawProviderRing(
        _ snapshot: ProviderRingSnapshot,
        center: NSPoint,
        accent: NSColor,
        isSelected: Bool,
        centerText: String?
    ) {
        let radius: CGFloat = isSelected ? 6.7 : 6.1
        let lineWidth: CGFloat = isSelected ? 2.35 : 2.05
        let trackRect = NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )

        let track = NSBezierPath(ovalIn: trackRect)
        accent.withAlphaComponent(snapshot.isProgressKnown ? 0.28 : 0.18).setStroke()
        track.lineWidth = lineWidth
        track.stroke()

        if snapshot.isProgressKnown {
            let clamped = min(max(snapshot.progress, 0), 1)
            if clamped >= 0.995 {
                let progressPath = NSBezierPath(ovalIn: trackRect)
                progressColor(providerAccent: accent, remainingPercent: snapshot.remainingPercent).setStroke()
                progressPath.lineWidth = lineWidth
                progressPath.stroke()
            } else if clamped > 0 {
                let startAngle: CGFloat = 90
                let endAngle = startAngle - CGFloat(360 * clamped)
                let progressPath = NSBezierPath()
                progressPath.appendArc(
                    withCenter: center,
                    radius: radius,
                    startAngle: startAngle,
                    endAngle: endAngle,
                    clockwise: true
                )
                progressColor(providerAccent: accent, remainingPercent: snapshot.remainingPercent).setStroke()
                progressPath.lineWidth = lineWidth
                progressPath.lineCapStyle = .round
                progressPath.stroke()
            }
        }

        if let centerText {
            drawCount(centerText, at: center)
        }
    }

    private static func progressColor(providerAccent: NSColor, remainingPercent: Int?) -> NSColor {
        guard let remainingPercent else {
            return providerAccent
        }

        switch remainingPercent {
        case ...9:
            return .systemRed
        case 10...24:
            return .systemOrange
        default:
            return providerAccent
        }
    }

    private static func drawCount(_ textValue: String, at center: NSPoint) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
        shadow.shadowBlurRadius = 1.2
        shadow.shadowOffset = .zero

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8.6, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.98),
            .paragraphStyle: paragraphStyle,
            .shadow: shadow,
        ]

        let text = textValue as NSString
        let textSize = text.size(withAttributes: attributes)
        let textRect = NSRect(
            x: center.x - 5,
            y: center.y - textSize.height / 2 - 0.35,
            width: 10,
            height: textSize.height + 1
        )
        text.draw(in: textRect, withAttributes: attributes)
    }
}
