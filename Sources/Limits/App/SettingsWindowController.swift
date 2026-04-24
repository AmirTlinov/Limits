import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var windowController: NSWindowController?
    private let languageDidChange: () -> Void
    private let windowVisibilityDidChange: () -> Void

    init(languageDidChange: @escaping () -> Void, windowVisibilityDidChange: @escaping () -> Void) {
        self.languageDidChange = languageDidChange
        self.windowVisibilityDidChange = windowVisibilityDidChange
        super.init()
    }

    var hasVisibleWindow: Bool {
        windowController?.window != nil
    }

    func show() {
        if let window = windowController?.window {
            RuntimeLog.window.info("settings window reused visible=\(window.isVisible, privacy: .public)")
            window.title = L10n.tr("settings.title")
            window.makeKeyAndOrderFront(nil)
            windowVisibilityDidChange()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: makeRootView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = L10n.tr("settings.title")
        window.setContentSize(NSSize(width: 520, height: 300))
        window.minSize = NSSize(width: 520, height: 300)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(nil)
        windowVisibilityDidChange()
        NSApp.activate(ignoringOtherApps: true)
        RuntimeLog.window.info("settings window opened")
    }

    func refreshLocalizedText() {
        guard let window = windowController?.window else { return }
        window.title = L10n.tr("settings.title")
        if let hostingController = window.contentViewController as? NSHostingController<SettingsView> {
            hostingController.rootView = makeRootView()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard
            let closedWindow = notification.object as? NSWindow,
            closedWindow === windowController?.window
        else {
            return
        }

        windowController = nil
        RuntimeLog.window.info("settings window closed")
        windowVisibilityDidChange()
    }

    private func makeRootView() -> SettingsView {
        SettingsView(languageDidChange: languageDidChange)
    }
}

struct SettingsView: View {
    let languageDidChange: () -> Void
    @State private var selectedLanguage: String

    init(languageDidChange: @escaping () -> Void) {
        self.languageDidChange = languageDidChange
        self._selectedLanguage = State(initialValue: L10n.selectedLanguageOverride ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("settings.title"))
                    .font(.title2.weight(.semibold))
                Text(L10n.tr("settings.subtitle"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.tr("settings.language.title"))
                    .font(.headline)
                Text(L10n.tr("settings.language.description"))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Picker(L10n.tr("settings.language.title"), selection: languageBinding) {
                    Text(L10n.tr("settings.language.system"))
                        .tag("")
                    ForEach(L10n.supportedLocalizations, id: \.self) { language in
                        Text(L10n.displayName(for: language))
                            .tag(language)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 260, alignment: .leading)
            }

            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { selectedLanguage },
            set: { newValue in
                selectedLanguage = newValue
                L10n.setLanguageOverride(newValue.isEmpty ? nil : newValue)
                languageDidChange()
            }
        )
    }
}
