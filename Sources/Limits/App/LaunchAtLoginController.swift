import Combine
import ServiceManagement

@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LaunchAtLoginServicing {}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    enum State: Equatable {
        case disabled
        case enabled
        case requiresApproval
        case unavailable

        var isRequested: Bool {
            self == .enabled || self == .requiresApproval
        }
    }

    @Published private(set) var state: State = .disabled
    @Published private(set) var errorMessage: String?

    private let service: any LaunchAtLoginServicing

    init(service: any LaunchAtLoginServicing = SMAppService.mainApp) {
        self.service = service
        refresh()
    }

    func refresh() {
        switch service.status {
        case .notRegistered:
            state = .disabled
        case .enabled:
            state = .enabled
        case .requiresApproval:
            state = .requiresApproval
        case .notFound:
            state = .unavailable
        @unknown default:
            state = .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
