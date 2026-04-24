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
            button.title = TrayStatusProvider.codex.displayTitle
            button.attributedTitle = statusTitle(TrayStatusProvider.codex.displayTitle)

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

        if let button = statusItem?.button {
            syncStatusButton(provider: provider, on: button)
        }

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

    private func syncStatusButton(provider: TrayStatusProvider, on button: NSStatusBarButton) {
        let title = provider.displayTitle
        button.image = nil
        button.imagePosition = .noImage
        button.title = title
        button.attributedTitle = statusTitle(title)
        button.setAccessibilityTitle(title)
        button.needsDisplay = true
    }

    private func statusTitle(_ title: String) -> NSAttributedString {
        NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuBarFont(ofSize: 0),
                .foregroundColor: NSColor.labelColor,
            ]
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
        row.title == "5ч лимит" || row.title.hasPrefix("5ч")
    }
}

private struct FiveHourLimitSnapshot {
    let remainingProgress: Double?
    let remainingPercent: Int?
    let resetText: String?
}
