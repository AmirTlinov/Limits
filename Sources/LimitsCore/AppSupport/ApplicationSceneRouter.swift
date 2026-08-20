import Foundation

extension Notification.Name {
    public static let limitsOpenAccountsWindow = Notification.Name("Limits.OpenAccountsWindow")
}

@MainActor
public final class ApplicationSceneRouter {
    public static let shared = ApplicationSceneRouter()

    private var accountsWindowRequestPending = false

    public init() {}

    public func requestAccountsWindow() {
        accountsWindowRequestPending = true
        NotificationCenter.default.post(name: .limitsOpenAccountsWindow, object: self)
    }

    public func consumeAccountsWindowRequest() -> Bool {
        guard accountsWindowRequestPending else { return false }
        accountsWindowRequestPending = false
        return true
    }
}
