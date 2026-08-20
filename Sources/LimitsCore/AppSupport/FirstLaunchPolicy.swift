import Foundation

public enum FirstLaunchPolicy {
    public static let completedFirstLaunchKey = "limits.completedFirstLaunch.v1"

    public static func shouldPresent(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: completedFirstLaunchKey)
    }

    public static func markPresented(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completedFirstLaunchKey)
    }
}

@MainActor
public enum ApplicationLaunchState {
    public static var presentsMainWindow = false
}
