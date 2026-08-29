import Foundation
import LimitsShared

@frozen public enum UsageRailSeverity: String, Equatable, Hashable, Sendable {
    case unknown
    case low
    case medium
    case high
    case critical
}

public struct UsageRailLimitRow: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let usedPercent: Int
    public let resetText: String?

    public init(id: String, title: String, usedPercent: Int, resetText: String?) {
        self.id = id
        self.title = title
        self.usedPercent = usedPercent
        self.resetText = resetText
    }

    public var progressValue: Double {
        min(max(Double(usedPercent) / 100, 0), 1)
    }

    public var severity: UsageRailSeverity {
        UsageRailPresentation.severity(usedPercent: usedPercent)
    }

    public var usedText: String {
        L10n.tr("rail.percent_used", usedPercent)
    }
}

/// One signed-in account. Codex can hold several; Claude tracks a single live session.
public struct UsageRailAccountGroup: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let rows: [UsageRailLimitRow]

    public init(id: String, title: String, rows: [UsageRailLimitRow]) {
        self.id = id
        self.title = title
        self.rows = rows
    }

    public var headline: UsageRailLimitRow? {
        rows.first
    }
}

public struct UsageRailItem: Identifiable, Equatable, Hashable, Sendable {
    public let id: LimitsWidgetProviderID
    public let title: String
    public let groups: [UsageRailAccountGroup]
    /// True when the numbers are the last known ones rather than a current reading.
    public let isStale: Bool
    public let updatedText: String?
    public let note: String?

    public init(
        id: LimitsWidgetProviderID,
        title: String,
        groups: [UsageRailAccountGroup],
        isStale: Bool,
        updatedText: String?,
        note: String?
    ) {
        self.id = id
        self.title = title
        self.groups = groups
        self.isStale = isStale
        self.updatedText = updatedText
        self.note = note
    }

    /// The ring reports the first account's leading row: for Codex the weekly allowance that
    /// binds first, for Claude the current session.
    public var usedPercent: Int? {
        groups.first?.headline?.usedPercent
    }

    public var hasData: Bool {
        usedPercent != nil
    }

    public var severity: UsageRailSeverity {
        UsageRailPresentation.severity(usedPercent: usedPercent)
    }

    public var progressValue: Double {
        guard let usedPercent else { return 0 }
        return min(max(Double(usedPercent) / 100, 0), 1)
    }

    public var metricText: String {
        guard let usedPercent else { return "—" }
        return "\(usedPercent)%"
    }

    public var headerText: String {
        L10n.tr("rail.usage_title", title)
    }

    /// Account names only earn their line when there is more than one to tell apart.
    public var showsAccountTitles: Bool {
        groups.count > 1
    }

    public var accessibilityLabel: String {
        guard let headline = groups.first?.headline else {
            return "\(headerText). \(note ?? L10n.tr("rail.no_data"))"
        }
        let reset = headline.resetText.map { ". \($0)" } ?? ""
        let stale = isStale ? ". \(updatedText ?? "")" : ""
        return "\(headerText). \(headline.title) \(headline.usedText)\(reset)\(stale)"
    }
}

/// What a surface hands in for one account before the rail decides which rows to show.
public struct UsageRailAccountInput: Equatable, Sendable {
    public let id: String
    public let title: String
    public let sections: [RateLimitDisplaySection]

    public init(id: String, title: String, sections: [RateLimitDisplaySection]) {
        self.id = id
        self.title = title
        self.sections = sections
    }
}

public struct UsageRailProviderInput: Equatable, Sendable {
    public let id: LimitsWidgetProviderID
    public let accounts: [UsageRailAccountInput]
    public let status: LimitsWidgetProviderStatus
    public let note: String?
    public let observedAt: Date?
    public let isStale: Bool

    public init(
        id: LimitsWidgetProviderID,
        accounts: [UsageRailAccountInput],
        status: LimitsWidgetProviderStatus,
        note: String? = nil,
        observedAt: Date? = nil,
        isStale: Bool = false
    ) {
        self.id = id
        self.accounts = accounts
        self.status = status
        self.note = note
        self.observedAt = observedAt
        self.isStale = isStale
    }
}

public enum UsageRailPresentation {
    /// Rail visibility is a user preference; the rail is on unless it was turned off.
    public static let enabledStorageKey = "limits.rail.enabled"

    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: enabledStorageKey) != nil else { return true }
        return defaults.bool(forKey: enabledStorageKey)
    }

    public static func severity(usedPercent: Int?) -> UsageRailSeverity {
        guard let usedPercent else { return .unknown }
        switch usedPercent {
        case ..<50: return .low
        case ..<70: return .medium
        case ..<90: return .high
        default: return .critical
        }
    }

    public static func items(from inputs: [UsageRailProviderInput], now: Date) -> [UsageRailItem] {
        inputs.map { item(from: $0, now: now) }
    }

    public static func item(from input: UsageRailProviderInput, now: Date) -> UsageRailItem {
        let groups = input.accounts.compactMap { account -> UsageRailAccountGroup? in
            let rows = rows(for: input.id, sections: account.sections)
            guard !rows.isEmpty else { return nil }
            return UsageRailAccountGroup(id: account.id, title: account.title, rows: rows)
        }

        let isStale = input.isStale && !groups.isEmpty
        return UsageRailItem(
            id: input.id,
            title: input.id.appearance.shortTitle,
            groups: groups,
            isStale: isStale,
            updatedText: isStale ? updatedText(observedAt: input.observedAt, now: now) : nil,
            note: groups.isEmpty ? (input.note ?? statusNote(for: input.status)) : nil
        )
    }

    /// Codex publishes several overlapping allowances; only the weekly one is worth a line, and
    /// when more than one weekly exists the binding constraint is the one furthest consumed.
    /// Claude gets its three windows in the order its own settings screen lists them.
    static func rows(
        for provider: LimitsWidgetProviderID,
        sections: [RateLimitDisplaySection]
    ) -> [UsageRailLimitRow] {
        let allRows = sections.flatMap(\.rows)

        switch provider {
        case .codex:
            guard let weekly = allRows.filter(\.isWeeklyWindow).max(by: { $0.usedPercent < $1.usedPercent }) else {
                return []
            }
            return [row(from: weekly)]
        case .claude:
            let order = [
                ClaudeLivePresentation.sessionRowID,
                ClaudeLivePresentation.allModelsRowID,
                ClaudeLivePresentation.topModelRowID,
            ]
            let ranked = allRows.sorted { lhs, rhs in
                let left = order.firstIndex(of: lhs.id) ?? order.count
                let right = order.firstIndex(of: rhs.id) ?? order.count
                return left < right
            }
            return ranked.map(row(from:))
        @unknown default:
            return allRows.map(row(from:))
        }
    }

    private static func row(from source: RateLimitDisplayRow) -> UsageRailLimitRow {
        UsageRailLimitRow(
            id: source.id,
            title: source.title,
            usedPercent: min(max(source.usedPercent, 0), 100),
            resetText: source.resetText
        )
    }

    private static func updatedText(observedAt: Date?, now: Date) -> String? {
        guard let observedAt, observedAt <= now else { return nil }
        let elapsed = now.timeIntervalSince(observedAt)
        guard elapsed >= 60 else { return nil }
        guard let duration = L10n.countdown(
            until: Int64(now.addingTimeInterval(elapsed).timeIntervalSince1970),
            now: now
        ) else {
            return nil
        }
        return L10n.tr("rail.updated_ago", duration)
    }

    private static func statusNote(for status: LimitsWidgetProviderStatus) -> String {
        switch status {
        case .available, .noData:
            return L10n.tr("rail.no_data")
        case .unavailable:
            return L10n.tr("rail.signed_out")
        case .error:
            return L10n.tr("rail.unavailable")
        @unknown default:
            return L10n.tr("rail.no_data")
        }
    }
}
