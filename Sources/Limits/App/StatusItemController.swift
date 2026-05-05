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
    private let statusItemLength: CGFloat = NSStatusItem.variableLength
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let trayIconRenderer = TrayStatusIconRenderer()
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
        button.imageScaling = .scaleNone
        button.image = nil
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
        let filter = currentTrayFilter()
        let codexSnapshot = currentFiveHourLimitSnapshot(for: .codex)
        let claudeSnapshot = currentFiveHourLimitSnapshot(for: .claude)
        let codexAvailability = providerAvailability(for: .codex, snapshot: codexSnapshot)
        let claudeAvailability = providerAvailability(for: .claude, snapshot: claudeSnapshot)
        let segments = TrayStatusPresentation.segments(filter: filter, codex: codexAvailability, claude: claudeAvailability)
        let title = TrayStatusPresentation.title(filter: filter, codex: codexAvailability, claude: claudeAvailability)
        let tooltip = tooltipText(
            codexSnapshot: codexSnapshot,
            claudeSnapshot: claudeSnapshot,
            codexAvailability: codexAvailability,
            claudeAvailability: claudeAvailability
        )

        guard let button = statusItem?.button else {
            RuntimeLog.tray.error("cannot refresh status item because button is missing")
            return
        }

        syncStatusButton(
            segments: segments,
            title: title,
            codexSnapshot: codexSnapshot,
            claudeSnapshot: claudeSnapshot,
            codexAvailability: codexAvailability,
            claudeAvailability: claudeAvailability,
            tooltip: tooltip,
            on: button
        )
        RuntimeLog.tray.debug("status item refreshed filter=\(filter.rawValue, privacy: .public) codexKnown=\(codexSnapshot.remainingPercent != nil, privacy: .public) claudeKnown=\(claudeSnapshot.remainingPercent != nil, privacy: .public) label=\(title, privacy: .public)")
    }

    private func syncStatusButton(
        segments: [TrayStatusPresentationSegment],
        title: String,
        codexSnapshot: FiveHourLimitSnapshot,
        claudeSnapshot: FiveHourLimitSnapshot,
        codexAvailability: TrayProviderAvailability,
        claudeAvailability: TrayProviderAvailability,
        tooltip: String,
        on button: NSStatusBarButton
    ) {
        if let image = trayIconRenderer.image(for: segments) {
            statusItem?.length = ceil(image.size.width + 10)
            button.image = image
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
        } else {
            statusItem?.length = statusItemLength
            button.image = nil
            button.imagePosition = .noImage
            button.imageScaling = .scaleProportionallyDown
            button.title = title
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11.2, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
        }
        button.toolTip = tooltip
        button.setAccessibilityLabel(accessibilityLabel(
            codexSnapshot: codexSnapshot,
            claudeSnapshot: claudeSnapshot,
            codexAvailability: codexAvailability,
            claudeAvailability: claudeAvailability
        ))
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

    private func tooltipText(
        codexSnapshot: FiveHourLimitSnapshot,
        claudeSnapshot: FiveHourLimitSnapshot,
        codexAvailability: TrayProviderAvailability,
        claudeAvailability: TrayProviderAvailability
    ) -> String {
        [
            tooltipText(provider: .codex, snapshot: codexSnapshot, availability: codexAvailability),
            tooltipText(provider: .claude, snapshot: claudeSnapshot, availability: claudeAvailability),
        ].joined(separator: " · ")
    }

    private func tooltipText(provider: TrayStatusProvider, snapshot: FiveHourLimitSnapshot, availability: TrayProviderAvailability) -> String {
        var tooltip = tooltipText(provider: provider, snapshot: snapshot)
        tooltip += " · \(L10n.limitAvailability(available: availability.availableAccounts, total: availability.totalAccounts))"
        return tooltip
    }

    private func accessibilitySegment(provider: TrayStatusProvider, snapshot: FiveHourLimitSnapshot, availability: TrayProviderAvailability) -> String {
        let base: String = if let remainingPercent = snapshot.remainingPercent {
            L10n.tr("tray.accessibility.five_hour", provider.displayTitle, remainingPercent)
        } else {
            L10n.tr("tray.accessibility.five_hour.no_data", provider.displayTitle)
        }
        return "\(base), \(L10n.limitAvailability(available: availability.availableAccounts, total: availability.totalAccounts))"
    }

    private func accessibilityLabel(
        codexSnapshot: FiveHourLimitSnapshot,
        claudeSnapshot: FiveHourLimitSnapshot,
        codexAvailability: TrayProviderAvailability,
        claudeAvailability: TrayProviderAvailability
    ) -> String {
        [
            accessibilitySegment(provider: .codex, snapshot: codexSnapshot, availability: codexAvailability),
            accessibilitySegment(provider: .claude, snapshot: claudeSnapshot, availability: claudeAvailability),
        ].joined(separator: " · ")
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

    private func currentTrayFilter() -> AccountsSidebarFilter {
        let rawFilter = UserDefaults.standard.string(forKey: AccountsSidebarFilter.providerFilterStorageKey)
        return rawFilter.flatMap(AccountsSidebarFilter.init(rawValue:)) ?? .all
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

    private func providerAvailability(for provider: TrayStatusProvider, snapshot: FiveHourLimitSnapshot) -> TrayProviderAvailability {
        switch provider {
        case .codex:
            return TrayProviderAvailability(
                remainingPercent: snapshot.remainingPercent,
                availableAccounts: availableCodexAccountCountWithLimits(),
                totalAccounts: visibleCodexAccountCount()
            )
        case .claude:
            return TrayProviderAvailability(
                remainingPercent: snapshot.remainingPercent,
                availableAccounts: snapshot.remainingPercent == nil ? 0 : 1,
                totalAccounts: visibleClaudeAccountCount()
            )
        }
    }

    private func availableCodexAccountCountWithLimits() -> Int {
        let currentCountsAsAvailable = currentCodexAccountCountsAsAvailableWithLimits()
        let storedOtherCount = model.accounts.filter { account in
            !model.isCurrentCLIAccount(account)
                && account.status == .ok
                && model.sidebarLimitSummary(for: account)?.hasLimitData == true
        }.count
        return (currentCountsAsAvailable ? 1 : 0) + storedOtherCount
    }

    private func currentCodexAccountCountsAsAvailableWithLimits() -> Bool {
        guard model.currentCLISidebarLimitSummary()?.hasLimitData == true else {
            return false
        }

        guard let account = model.currentCLIReferenceAccount() else {
            return true
        }

        return account.status == .ok
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
