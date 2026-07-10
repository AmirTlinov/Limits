import ServiceManagement
import Testing
@testable import Limits

@MainActor
@Test func launchAtLoginControllerRegistersAndUnregistersMainApp() {
    let service = LaunchAtLoginServiceDouble()
    let controller = LaunchAtLoginController(service: service)

    #expect(controller.state == .disabled)
    controller.setEnabled(true)
    #expect(service.registerCallCount == 1)
    #expect(controller.state == .enabled)

    controller.setEnabled(false)
    #expect(service.unregisterCallCount == 1)
    #expect(controller.state == .disabled)
}

@MainActor
@Test func launchAtLoginControllerKeepsApprovalRequestVisible() {
    let service = LaunchAtLoginServiceDouble(status: .requiresApproval)
    let controller = LaunchAtLoginController(service: service)

    #expect(controller.state == .requiresApproval)
    #expect(controller.state.isRequested)
}

@MainActor
private final class LaunchAtLoginServiceDouble: LaunchAtLoginServicing {
    var status: SMAppService.Status
    var registerCallCount = 0
    var unregisterCallCount = 0

    init(status: SMAppService.Status = .notRegistered) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        status = .notRegistered
    }
}
