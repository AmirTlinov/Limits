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
    private var trayPanel: NSPanel?
    private let trayIconRenderer = TrayStatusIconRenderer()
    private var modelCancellable: AnyCancellable?
    private var defaultsCancellable: AnyCancellable?
    private var languageCancellable: AnyCancellable?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var trayPanelResizeTask: Task<Void, Never>?

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

        rebuildTrayPanelContent()
        startObservingModel()
        refreshStatusItemAppearance()

        let snapshot = installSnapshot(for: item, isNewInstall: true)
        RuntimeLog.tray.info("status item installed hasButton=\(snapshot.hasButton, privacy: .public) hasImage=\(snapshot.hasImage, privacy: .public) length=\(Double(snapshot.length), privacy: .public) label=\(snapshot.visibleLabel, privacy: .public)")
        return snapshot
    }

    func openAccountsWindowFromTray() {
        closeTrayPanel()
        RuntimeLog.tray.info("open accounts window requested from tray")
        openAccountsWindow()
    }

    func openSettingsWindowFromTray() {
        closeTrayPanel()
        RuntimeLog.tray.info("open settings window requested from tray")
        openSettingsWindow()
    }

    func refreshLocalizedText() {
        rebuildTrayPanelContent(screen: trayPanel?.screen)
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
        button.action = #selector(toggleTrayPanel(_:))
        button.toolTip = "Limits"
        button.setAccessibilityLabel(TrayStatusProvider.codex.displayTitle)
        button.setAccessibilityTitle(TrayStatusProvider.codex.displayTitle)
    }

    private func rebuildTrayPanelContent(screen: NSScreen? = nil) {
        let content = MenuBarContentView(
            model: model,
            openAccountsWindow: { [weak self] in
                self?.openAccountsWindowFromTray()
            },
            openSettingsWindow: { [weak self] in
                self?.openSettingsWindowFromTray()
            },
            maxScrollableContentHeight: trayScrollableContentHeight(for: screen),
            providerFilterDidChange: { [weak self] filter in
                self?.handleProviderFilterDidChange(filter)
            }
        )
        let rootView = TrayPanelChromeView {
            content
        }
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor

        let size = trayPanelSize(for: hostingController, screen: screen)
        hostingController.view.frame = NSRect(origin: .zero, size: size)

        let panel = trayPanel ?? makeTrayPanel(size: size)
        panel.contentViewController = hostingController
        panel.setContentSize(size)
        trayPanel = panel
    }

    private func makeTrayPanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        return panel
    }

    private func trayPanelSize(for hostingController: NSHostingController<TrayPanelChromeView<MenuBarContentView>>, screen: NSScreen?) -> NSSize {
        let width: CGFloat = 350
        let maxHeight = trayPanelMaxHeight(for: screen)
        let fittingSize = hostingController.sizeThatFits(in: NSSize(width: width, height: maxHeight))
        let height = min(maxHeight, max(1, fittingSize.height))
        return NSSize(width: width, height: height)
    }

    private func trayScrollableContentHeight(for screen: NSScreen?) -> CGFloat {
        let visibleHeight = screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 900
        return min(500, max(320, visibleHeight * 0.50))
    }

    private func trayPanelMaxHeight(for screen: NSScreen?) -> CGFloat {
        let visibleHeight = screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 900
        return min(640, max(360, visibleHeight - 120))
    }

    private func handleProviderFilterDidChange(_: AccountsSidebarFilter) {
        refreshStatusItemAppearance()
        scheduleVisibleTrayPanelResize()
    }

    private func scheduleVisibleTrayPanelResize() {
        trayPanelResizeTask?.cancel()
        trayPanelResizeTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.resizeVisibleTrayPanel()
            self?.trayPanelResizeTask = nil
        }
    }

    private func resizeVisibleTrayPanel() {
        guard
            let panel = trayPanel,
            panel.isVisible,
            let button = statusItem?.button,
            let buttonWindow = button.window
        else { return }

        let screen = buttonWindow.screen ?? panel.screen
        button.layoutSubtreeIfNeeded()

        guard let hostingController = panel.contentViewController as? NSHostingController<TrayPanelChromeView<MenuBarContentView>> else {
            rebuildTrayPanelContent(screen: screen)
            guard let rebuiltPanel = trayPanel else { return }
            rebuiltPanel.setFrame(trayPanelFrame(relativeTo: button, in: buttonWindow), display: true)
            return
        }

        hostingController.view.needsLayout = true
        hostingController.view.layoutSubtreeIfNeeded()
        let size = trayPanelSize(for: hostingController, screen: screen)
        hostingController.view.frame = NSRect(origin: .zero, size: size)
        panel.setFrame(trayPanelFrame(relativeTo: button, in: buttonWindow, size: size), display: true)
    }

    @objc private func toggleTrayPanel(_ sender: NSStatusBarButton) {
        if trayPanel?.isVisible == true {
            closeTrayPanel()
        } else {
            showTrayPanel(relativeTo: sender)
        }
    }

    private func showTrayPanel(relativeTo sender: NSStatusBarButton) {
        let button = statusItem?.button ?? sender
        guard let buttonWindow = button.window else {
            RuntimeLog.tray.error("cannot show tray panel because status button is detached")
            return
        }

        RuntimeLog.tray.info("tray panel opened")
        rebuildTrayPanelContent(screen: buttonWindow.screen)
        guard let panel = trayPanel else { return }
        button.layoutSubtreeIfNeeded()
        panel.setFrame(trayPanelFrame(relativeTo: button, in: buttonWindow), display: false)
        panel.orderFrontRegardless()
        startEventMonitoring()
    }

    private func trayPanelFrame(relativeTo button: NSStatusBarButton, in buttonWindow: NSWindow, size explicitSize: NSSize? = nil) -> NSRect {
        let anchorInWindow = button.convert(button.bounds, to: nil)
        let anchor = buttonWindow.convertToScreen(anchorInWindow)
        let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchor
        let size = explicitSize ?? trayPanel?.frame.size ?? NSSize(width: 350, height: 420)
        let x = min(
            max(anchor.midX - size.width / 2, screenFrame.minX + 8),
            screenFrame.maxX - size.width - 8
        )
        let y = max(anchor.minY - size.height - 8, screenFrame.minY + 8)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func closeTrayPanel() {
        if trayPanel?.isVisible == true {
            RuntimeLog.tray.info("tray panel closed")
        }
        trayPanel?.orderOut(nil)
        trayPanelResizeTask?.cancel()
        trayPanelResizeTask = nil
        stopEventMonitoring()
    }

    private func startEventMonitoring() {
        stopEventMonitoring()

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window === self.trayPanel || event.window === self.statusItem?.button?.window {
                return event
            }
            self.closeTrayPanel()
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closeTrayPanel()
            }
        }
    }

    private func stopEventMonitoring() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func startObservingModel() {
        modelCancellable = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.refreshStatusItemAppearance()
                self?.scheduleVisibleTrayPanelResize()
            }
        }

        defaultsCancellable = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshStatusItemAppearance()
                    self?.scheduleVisibleTrayPanelResize()
                }
            }

        languageCancellable = NotificationCenter.default.publisher(for: L10n.languageDidChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshLocalizedText()
                    self?.scheduleVisibleTrayPanelResize()
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
        let currentCountsAsAccount = switch model.currentCLIState.source {
        case .stored, .external:
            true
        case .missing, .unreadable:
            false
        }

        let storedOtherCount = model.accounts.filter { !model.isCurrentCLIAccount($0) }.count
        return (currentCountsAsAccount ? 1 : 0) + storedOtherCount
    }

    private func visibleClaudeAccountCount() -> Int {
        let currentCountsAsAccount = switch model.currentClaudeState.source {
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

private struct TrayPanelChromeView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.primary.opacity(0.08), lineWidth: 1)
            }
    }
}
