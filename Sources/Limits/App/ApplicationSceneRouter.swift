import Foundation

extension Notification.Name {
    static let limitsOpenAccountsWindow = Notification.Name("Limits.OpenAccountsWindow")
}

@MainActor
final class ApplicationSceneRouter {
    static let shared = ApplicationSceneRouter()

    private var accountsWindowRequestPending = false

    func requestAccountsWindow() {
        accountsWindowRequestPending = true
        NotificationCenter.default.post(name: .limitsOpenAccountsWindow, object: self)
    }

    func consumeAccountsWindowRequest() -> Bool {
        guard accountsWindowRequestPending else { return false }
        accountsWindowRequestPending = false
        return true
    }
}
