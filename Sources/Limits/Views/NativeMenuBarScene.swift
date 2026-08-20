import AppKit
import SwiftUI
import LimitsCore

struct NativeMenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        MenuBarContentView(
            model: model,
            openAccountsWindow: openAccountsWindow,
            openSettingsWindow: openSettingsWindow
        )
        .task {
            await model.refreshForPresentation()
        }
    }

    private func openAccountsWindow() {
        ApplicationActivationController.shared.requestActivation(of: .accounts)
        openWindow(id: LimitsSceneID.accounts)
    }

    private func openSettingsWindow() {
        ApplicationActivationController.shared.requestActivation(of: .settings)
        openSettings()
    }
}

struct NativeMenuBarLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AccountsSidebarFilter.providerFilterStorageKey) private var filterRaw = AccountsSidebarFilter.all.rawValue
    private let renderer = TrayStatusIconRenderer()

    var body: some View {
        let filter = model.providerCatalog.normalized(AccountsSidebarFilter(rawValue: filterRaw) ?? .all)
        let snapshot = model.trayStatusSnapshot(filter: filter, now: model.presentationNow)

        Group {
            if let image = renderer.image(for: snapshot.segments) {
                Image(nsImage: image)
                    .renderingMode(.template)
            } else {
                Text(snapshot.title)
                    .monospacedDigit()
            }
        }
        .help(snapshot.tooltip)
        .accessibilityLabel(snapshot.accessibilityLabel)
        .task {
            filterRaw = filter.rawValue
            openAccountsWindowIfRequested()
        }
        .onReceive(NotificationCenter.default.publisher(for: .limitsOpenAccountsWindow)) { _ in
            openAccountsWindowIfRequested()
        }
        .onChange(of: model.providerCatalog) { _, catalog in
            filterRaw = catalog.normalized(AccountsSidebarFilter(rawValue: filterRaw) ?? .all).rawValue
        }
    }

    private func openAccountsWindowIfRequested() {
        guard ApplicationSceneRouter.shared.consumeAccountsWindowRequest() else { return }
        Task { await model.refreshForPresentation() }
        ApplicationActivationController.shared.requestActivation(of: .accounts)
        openWindow(id: LimitsSceneID.accounts)
    }
}
