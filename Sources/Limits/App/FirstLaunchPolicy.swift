import Foundation

enum FirstLaunchPolicy {
    static let completedFirstLaunchKey = "limits.completedFirstLaunch.v1"

    static func consumeFirstLaunch(defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: completedFirstLaunchKey) else {
            return false
        }
        defaults.set(true, forKey: completedFirstLaunchKey)
        return true
    }
}

@MainActor
enum ApplicationLaunchState {
    static var presentsMainWindow = false
}
