import AppKit
import SwiftUI

final class LimitsAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
    }
}

@main
struct LimitsApp: App {
    @NSApplicationDelegateAdaptor(LimitsAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("Лимиты", id: "accounts") {
            AccountsWindowView(model: model)
        }

        MenuBarExtra {
            MenuBarContentView(model: model) {
                openWindow(id: "accounts")
                NSApp.activate(ignoringOtherApps: true)
            }
        } label: {
            Image(systemName: "speedometer")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 14, weight: .semibold))
                .accessibilityLabel("Лимиты")
        }
        .menuBarExtraStyle(.window)
    }
}
