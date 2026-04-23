import AppKit
import SwiftUI

final class LimitsAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct LimitsApp: App {
    @NSApplicationDelegateAdaptor(LimitsAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("Accounts", id: "accounts") {
            AccountsWindowView(model: model)
        }

        MenuBarExtra("Limits", systemImage: "person.crop.circle.badge.checkmark") {
            MenuBarContentView(model: model) {
                openWindow(id: "accounts")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
