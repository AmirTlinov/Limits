import AppKit
import SwiftUI

enum ApplicationWindowKind: Sendable {
    case accounts
    case settings
}

@MainActor
final class ApplicationActivationController {
    static let shared = ApplicationActivationController()

    private var attachmentCounts: [ObjectIdentifier: Int] = [:]
    private var trackedWindows: [ObjectIdentifier: (window: NSWindow, kind: ApplicationWindowKind)] = [:]
    private var windowObservers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    private var requestedActivation: ApplicationWindowKind?

    func synchronize() {
        syncActivationPolicy()
        activatePresentedWindowIfRequested()
    }

    func requestActivation(of kind: ApplicationWindowKind) {
        requestedActivation = kind
        RuntimeLog.lifecycle.debug("window activation requested kind=\(kind == .accounts ? "accounts" : "settings", privacy: .public)")
        activatePresentedWindowIfRequested()
    }

    func attach(_ window: NSWindow, kind: ApplicationWindowKind) {
        let id = ObjectIdentifier(window)
        attachmentCounts[id, default: 0] += 1
        trackedWindows[id] = (window, kind)
        if windowObservers[id] == nil {
            let names: [Notification.Name] = [
                NSWindow.willCloseNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                NSWindow.didMoveNotification,
                NSWindow.didResizeNotification,
            ]
            windowObservers[id] = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        if name == NSWindow.willCloseNotification {
                            Task { @MainActor [weak self] in
                                await Task.yield()
                                self?.synchronize()
                            }
                        } else {
                            self?.synchronize()
                        }
                    }
                }
            }
        }
        syncActivationPolicy()
        activatePresentedWindowIfRequested()
    }

    func detach(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard let count = attachmentCounts[id] else { return }
        if count > 1 {
            attachmentCounts[id] = count - 1
        } else {
            removeWindow(id: id)
        }
        syncActivationPolicy()
    }

    private func removeWindow(id: ObjectIdentifier) {
        attachmentCounts.removeValue(forKey: id)
        trackedWindows.removeValue(forKey: id)
        if let observers = windowObservers.removeValue(forKey: id) {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
        syncActivationPolicy()
    }

    private func syncActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = hasPresentedWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        RuntimeLog.lifecycle.info("activation policy changed policy=\(policy == .regular ? "regular" : "accessory", privacy: .public)")
    }

    private func activatePresentedWindowIfRequested() {
        guard
            let requestedActivation,
            let tracked = trackedWindows.values.first(where: { $0.kind == requestedActivation }),
            isPresentationFrameReady(tracked.window)
        else {
            return
        }
        self.requestedActivation = nil
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        tracked.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RuntimeLog.lifecycle.info("window activated kind=\(requestedActivation == .accounts ? "accounts" : "settings", privacy: .public)")
        Task { @MainActor [weak self, weak window = tracked.window] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, let window, isWindowPresented(window) else { return }
            window.makeKeyAndOrderFront(nil)
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
    }

    private var hasPresentedWindow: Bool {
        trackedWindows.values.contains { isWindowPresented($0.window) }
    }

    private func isWindowPresented(_ window: NSWindow) -> Bool {
        if window.isMiniaturized {
            return true
        }
        guard window.isVisible else { return false }
        return NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }

    private func isPresentationFrameReady(_ window: NSWindow) -> Bool {
        guard window.frame.width >= 320, window.frame.height >= 240 else { return false }
        return NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }
}

struct WindowActivationTracker: NSViewRepresentable {
    let kind: ApplicationWindowKind

    func makeNSView(context: Context) -> WindowTrackingView {
        WindowTrackingView(kind: kind)
    }

    func updateNSView(_ nsView: WindowTrackingView, context: Context) {}

    static func dismantleNSView(_ nsView: WindowTrackingView, coordinator: Void) {
        nsView.detachTrackedWindow()
    }
}

final class WindowTrackingView: NSView {
    private let kind: ApplicationWindowKind
    private weak var trackedWindow: NSWindow?

    init(kind: ApplicationWindowKind) {
        self.kind = kind
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard trackedWindow !== window else { return }
        detachTrackedWindow()
        guard let window else { return }
        trackedWindow = window
        ApplicationActivationController.shared.attach(window, kind: kind)
    }

    func detachTrackedWindow() {
        guard let trackedWindow else { return }
        ApplicationActivationController.shared.detach(trackedWindow)
        self.trackedWindow = nil
    }
}
