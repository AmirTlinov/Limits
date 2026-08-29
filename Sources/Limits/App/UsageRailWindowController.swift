import AppKit
import SwiftUI
import LimitsCore
import LimitsShared

/// Hosts the floating usage rail: a borderless, non-activating panel pinned to the right edge
/// of the primary screen. The panel is only as wide as the rail itself so it never swallows
/// clicks meant for the app underneath; it widens to the left while a detail bubble is open.
@MainActor
final class UsageRailWindowController {
    static let shared = UsageRailWindowController()

    private static let topInset: CGFloat = 8
    private static let initialContentHeight: CGFloat = 240

    private var panel: NSPanel?
    private var model: AppModel?
    private var hovered: LimitsWidgetProviderID?
    private var contentHeight = UsageRailWindowController.initialContentHeight
    private var observers: [NSObjectProtocol] = []

    private init() {}

    var isEnabled: Bool {
        UsageRailPresentation.isEnabled(in: .standard)
    }

    func attach(model: AppModel) {
        guard self.model == nil else {
            applyEnabledState()
            return
        }
        // The rail floats above every space; letting it appear during UI tests would put an
        // always-on-top window over the fixtures the suite drives.
        guard !LimitsRuntimeEnvironment.current.isUITest else { return }

        self.model = model
        installObservers()
        applyEnabledState()
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UsageRailPresentation.enabledStorageKey)
        applyEnabledState()
    }

    func applyEnabledState() {
        guard model != nil else { return }
        if isEnabled {
            showPanel()
        } else {
            hidePanel()
        }
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in UsageRailWindowController.shared.layoutPanel() }
            }
        )
        observers.append(
            center.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: UserDefaults.standard,
                queue: .main
            ) { _ in
                Task { @MainActor in UsageRailWindowController.shared.applyEnabledState() }
            }
        )
    }

    private func showPanel() {
        guard let model else { return }

        if panel == nil {
            let panel = NSPanel(
                contentRect: CGRect(x: 0, y: 0, width: UsageRailMetrics.railWidth, height: contentHeight),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.acceptsMouseMovedEvents = true
            panel.isMovableByWindowBackground = false
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none

            let rootView = UsageRailRootView(
                model: model,
                onHoverChange: { [weak self] provider in
                    self?.setHovered(provider)
                },
                onHeightChange: { [weak self] height in
                    self?.setContentHeight(height)
                },
                openAccountsWindow: { [weak self] in
                    self?.openAccountsWindow()
                }
            )
            panel.contentView = NSHostingView(rootView: rootView)
            self.panel = panel
        }

        layoutPanel()
        panel?.orderFrontRegardless()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        hovered = nil
    }

    private func setHovered(_ provider: LimitsWidgetProviderID?) {
        guard hovered != provider else { return }
        hovered = provider
        layoutPanel()
    }

    private func setContentHeight(_ height: CGFloat) {
        let rounded = height.rounded(.up)
        guard rounded > 0, abs(rounded - contentHeight) >= 0.5 else { return }
        contentHeight = rounded
        layoutPanel()
    }

    /// The rail is anchored to the primary screen rather than `NSScreen.main` so it does not
    /// hop between displays as the user moves focus.
    private var anchorScreen: NSScreen? {
        NSScreen.screens.first ?? NSScreen.main
    }

    private func layoutPanel() {
        guard let panel, let screen = anchorScreen else { return }

        let area = screen.visibleFrame
        let width = hovered == nil ? UsageRailMetrics.railWidth : UsageRailMetrics.expandedWidth
        let height = min(max(contentHeight, 1), area.height)
        let frame = CGRect(
            x: area.maxX - width,
            y: area.maxY - Self.topInset - height,
            width: width,
            height: height
        )

        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
    }

    /// Same route the dock-reopen path uses: the menu bar label observes the router and owns
    /// the SwiftUI `openWindow` action, and activation is handled once the window is on screen.
    private func openAccountsWindow() {
        ApplicationActivationController.shared.requestActivation(of: .accounts)
        ApplicationSceneRouter.shared.requestAccountsWindow()
    }
}
