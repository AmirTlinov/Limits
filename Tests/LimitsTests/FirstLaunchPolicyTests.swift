import Foundation
import Testing
@testable import Limits

@Test func firstLaunchPolicyPresentsExactlyOnce() throws {
    let suiteName = "limits-first-launch-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(FirstLaunchPolicy.consumeFirstLaunch(defaults: defaults))
    #expect(!FirstLaunchPolicy.consumeFirstLaunch(defaults: defaults))
}
