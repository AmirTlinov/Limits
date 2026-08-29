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

public struct UsageRailItem: Identifiable, Equatable, Hashable, Sendable {
    public let id: LimitsWidgetProviderID
    public let title: String
    public let accountTitle: String
    public let usedPercent: Int?
    public let rows: [UsageRailLimitRow]
    public let note: String?

    public init(
        id: LimitsWidgetProviderID,
        title: String,
        accountTitle: String,
        usedPercent: Int?,
        rows: [UsageRailLimitRow],
        note: String?
    ) {
        self.id = id
        self.title = title
        self.accountTitle = accountTitle
        self.usedPercent = usedPercent
        self.rows = rows
        self.note = note
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

    public var accessibilityLabel: String {
        guard let headline = rows.first else {
            return "\(headerText). \(note ?? L10n.tr("rail.no_data"))"
        }
        let reset = headline.resetText.map { ". \($0)" } ?? ""
        return "\(headerText). \(headline.title) \(headline.usedText)\(reset)"
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

    public static func items(from snapshot: LimitsWidgetSnapshot, now: Date) -> [UsageRailItem] {
        snapshot.providers.map { item(from: $0, now: now) }
    }

    public static func item(from provider: LimitsWidgetProviderSnapshot, now: Date) -> UsageRailItem {
        let rows = rows(from: provider, now: now)
        return UsageRailItem(
            id: provider.id,
            title: provider.id.appearance.shortTitle,
            accountTitle: provider.title,
            usedPercent: headlineRow(in: rows)?.usedPercent,
            rows: rows,
            note: rows.isEmpty ? (provider.note ?? statusNote(for: provider.status)) : nil
        )
    }

    /// The ring mirrors the tray: the session window when it is known, otherwise the first fresh limit.
    public static func headlineRow(in rows: [UsageRailLimitRow]) -> UsageRailLimitRow? {
        rows.first { $0.title == L10n.tr("limit.five_hour") } ?? rows.first
    }

    private static func rows(from provider: LimitsWidgetProviderSnapshot, now: Date) -> [UsageRailLimitRow] {
        provider.limitsForCompactSurface(at: now).compactMap { limit in
            guard let remainingPercent = limit.remainingPercent else { return nil }
            return UsageRailLimitRow(
                id: limit.id,
                title: limit.title,
                usedPercent: min(max(100 - remainingPercent, 0), 100),
                resetText: limit.resetDate.map { RateLimitResetFormatter.expandedText(for: $0, now: now) }
            )
        }
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
