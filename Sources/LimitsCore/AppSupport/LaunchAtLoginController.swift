import Combine
import ServiceManagement

@MainActor
public protocol LaunchAtLoginServicing: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LaunchAtLoginServicing {}

@MainActor
public final class LaunchAtLoginController: ObservableObject {
    @frozen public enum State: Equatable {
        case disabled
        case enabled
        case requiresApproval
        case unavailable

        public var isRequested: Bool {
            self == .enabled || self == .requiresApproval
        }
    }

    @Published public private(set) var state: State = .disabled
    @Published public private(set) var errorMessage: String?

    private let service: any LaunchAtLoginServicing

    public init(service: any LaunchAtLoginServicing = SMAppService.mainApp) {
        self.service = service
        refresh()
    }

    public func refresh() {
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

    public func setEnabled(_ enabled: Bool) {
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

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
