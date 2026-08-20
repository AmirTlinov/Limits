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
    public let observedAt: Date?
    public let freshUntil: Date?
    public let note: String?

    public init(
        id: LimitsWidgetProviderID,
        title: String,
        subtitle: String?,
        status: LimitsWidgetProviderStatus,
        limits: [LimitsWidgetLimitSnapshot],
        observedAt: Date?,
        freshUntil: Date?,
        note: String?
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.limits = limits
        self.observedAt = observedAt
        self.freshUntil = freshUntil
        self.note = note
    }

    public var hasKnownLimits: Bool {
        limits.contains { $0.remainingPercent != nil }
    }

    public func isFresh(at date: Date) -> Bool {
        guard let observedAt, let freshUntil else { return false }
        return observedAt <= date && date < freshUntil
    }

    public func limitsForCompactSurface(at date: Date) -> [LimitsWidgetLimitSnapshot] {
        guard isFresh(at: date) else { return [] }
        return limits.filter { limit in
            guard limit.remainingPercent != nil else { return false }
            return limit.resetDate.map { $0 > date } ?? true
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case subtitle
        case status
        case limits
        case observedAt
        case freshUntil
        case updatedAt
        case note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(LimitsWidgetProviderID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        status = try container.decode(LimitsWidgetProviderStatus.self, forKey: .status)
        limits = try container.decodeIfPresent([LimitsWidgetLimitSnapshot].self, forKey: .limits) ?? []
        observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt)
            ?? container.decodeIfPresent(Date.self, forKey: .updatedAt)
        freshUntil = try container.decodeIfPresent(Date.self, forKey: .freshUntil)
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encode(status, forKey: .status)
        try container.encode(limits, forKey: .limits)
        try container.encodeIfPresent(observedAt, forKey: .observedAt)
        try container.encodeIfPresent(freshUntil, forKey: .freshUntil)
        try container.encodeIfPresent(note, forKey: .note)
    }
}

public struct LimitsWidgetSnapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

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

public enum LimitsFreshnessPolicy {
    public static let defaultTTL: TimeInterval = 15 * 60

    public static func isFresh(
        observedAt: Date?,
        at date: Date,
        ttl: TimeInterval = defaultTTL
    ) -> Bool {
        guard let observedAt else { return false }
        return observedAt <= date && date < observedAt.addingTimeInterval(ttl)
    }

    public static func freshUntil(
        observedAt: Date?,
        limitResetDates: [Date],
        ttl: TimeInterval = defaultTTL
    ) -> Date? {
        guard let observedAt else { return nil }
        return ([observedAt.addingTimeInterval(ttl)] + limitResetDates).min()
    }
}
