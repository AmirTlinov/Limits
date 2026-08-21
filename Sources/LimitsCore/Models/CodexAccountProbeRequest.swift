import Foundation

public struct CodexAccountProbeRequest: Hashable, Sendable {
    public let rateLimits: Bool
    public let accountUsage: Bool

    public init(rateLimits: Bool, accountUsage: Bool) {
        self.rateLimits = rateLimits
        self.accountUsage = accountUsage
    }

    public static let identity = Self(rateLimits: false, accountUsage: false)
    public static let limits = Self(rateLimits: true, accountUsage: false)
    public static let usage = Self(rateLimits: false, accountUsage: true)
    public static let all = Self(rateLimits: true, accountUsage: true)

    public func covers(_ other: Self) -> Bool {
        (!other.rateLimits || rateLimits) && (!other.accountUsage || accountUsage)
    }
}
