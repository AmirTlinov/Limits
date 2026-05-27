import Foundation

public enum LimitsWidgetProviderID: String, Codable, Hashable, Sendable, CaseIterable {
    case codex
    case claude
}

public enum LimitsWidgetProviderStatus: String, Codable, Hashable, Sendable {
    case available
    case unavailable
    case noData
    case error
}

public struct LimitsWidgetLimitSnapshot: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let remainingPercent: Int?
    public let resetDate: Date?

    public init(id: String, title: String, remainingPercent: Int?, resetDate: Date?) {
        self.id = id
        self.title = title
        self.remainingPercent = remainingPercent
        self.resetDate = resetDate
    }
}

public struct LimitsWidgetProviderSnapshot: Codable, Hashable, Sendable, Identifiable {
    public let id: LimitsWidgetProviderID
    public let title: String
    public let subtitle: String?
    public let status: LimitsWidgetProviderStatus
    public let limits: [LimitsWidgetLimitSnapshot]
    public let updatedAt: Date?
    public let note: String?

    public init(
        id: LimitsWidgetProviderID,
        title: String,
        subtitle: String?,
        status: LimitsWidgetProviderStatus,
        limits: [LimitsWidgetLimitSnapshot],
        updatedAt: Date?,
        note: String?
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.limits = limits
        self.updatedAt = updatedAt
        self.note = note
    }

    public var hasKnownLimits: Bool {
        limits.contains { $0.remainingPercent != nil }
    }
}

public struct LimitsWidgetSnapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let providers: [LimitsWidgetProviderSnapshot]

    public init(schemaVersion: Int = Self.currentSchemaVersion, generatedAt: Date, providers: [LimitsWidgetProviderSnapshot]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.providers = providers
    }

    public func provider(_ id: LimitsWidgetProviderID) -> LimitsWidgetProviderSnapshot? {
        providers.first { $0.id == id }
    }
}
