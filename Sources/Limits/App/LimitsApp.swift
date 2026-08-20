import AppKit
import LimitsCore
import LimitsShared
import SwiftUI

@MainActor
final class LimitsApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if !ApplicationLaunchState.presentsMainWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !LimitsRuntimeEnvironment.current.disablesExternalProbes {
            SoftwareUpdateController.shared.start()
        }
        if ApplicationLaunchState.presentsMainWindow {
            ApplicationActivationController.shared.requestActivation(of: .accounts)
            ApplicationSceneRouter.shared.requestAccountsWindow()
        }
        RuntimeLog.lifecycle.info("native SwiftUI application launched")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            ApplicationSceneRouter.shared.requestAccountsWindow()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
@MainActor
struct LimitsApp: App {
    @NSApplicationDelegateAdaptor(LimitsApplicationDelegate.self) private var applicationDelegate
    @StateObject private var model: AppModel
    private let presentMainWindowAtLaunch: Bool
    private let recordsFirstWindowPresentation: Bool

    init() {
        _model = StateObject(wrappedValue: AppModel())
        let runtime = LimitsRuntimeEnvironment.current
        presentMainWindowAtLaunch = runtime.isUITest || FirstLaunchPolicy.shouldPresent()
        recordsFirstWindowPresentation = !runtime.isUITest
        ApplicationLaunchState.presentsMainWindow = presentMainWindowAtLaunch
    }

    var body: some Scene {
        Window(L10n.tr("app.title"), id: LimitsSceneID.accounts) {
            AccountsWindowView(model: model)
                .background(WindowActivationTracker(kind: .accounts))
                .onAppear {
                    if presentMainWindowAtLaunch, recordsFirstWindowPresentation {
                        FirstLaunchPolicy.markPresented()
                    }
                }
                .onOpenURL { url in
                    guard url.scheme == LimitsWidgetConstants.openURL.scheme else { return }
                    ApplicationActivationController.shared.requestActivation(of: .accounts)
                    ApplicationSceneRouter.shared.requestAccountsWindow()
                }
        }
        .defaultSize(width: 980, height: 620)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(presentMainWindowAtLaunch ? .presented : .suppressed)
        .handlesExternalEvents(matching: ["open"])
        MenuBarExtra {
            NativeMenuBarContent(model: model)
        } label: {
            NativeMenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(
                catalog: model.providerCatalog,
                languageDidChange: {
                    model.invalidateLocalizedText()
                    model.publishWidgetSnapshotNow()
                },
                checkForUpdates: {
                    SoftwareUpdateController.shared.checkForUpdates()
                }
            )
            .background(WindowActivationTracker(kind: .settings))
        }
    }
}

enum LimitsSceneID {
    static let accounts = "accounts"
}
