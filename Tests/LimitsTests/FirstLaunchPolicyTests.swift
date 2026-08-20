import Foundation
import Testing
@testable import LimitsCore

@Test func firstLaunchPolicyMarksOnlyAnActuallyPresentedWindow() throws {
    let suiteName = "limits-first-launch-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(FirstLaunchPolicy.shouldPresent(defaults: defaults))
    #expect(FirstLaunchPolicy.shouldPresent(defaults: defaults))
    FirstLaunchPolicy.markPresented(defaults: defaults)
    #expect(!FirstLaunchPolicy.shouldPresent(defaults: defaults))
}
