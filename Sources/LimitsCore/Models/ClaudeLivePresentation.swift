import Foundation
import LimitsShared

public enum ClaudeLivePresentation {
    public static let sessionRowID = "claude.five_hour"
    public static let allModelsRowID = "claude.seven_day"
    public static let topModelRowID = "claude.seven_day_opus"

    public static func rateLimitSections(
        evidence: ClaudeLiveEvidence?,
        now: Date = .now,
        ttl: TimeInterval = LimitsFreshnessPolicy.defaultTTL
    ) -> [RateLimitDisplaySection] {
        guard let evidence, LimitsFreshnessPolicy.isFresh(observedAt: evidence.snapshotAt, at: now, ttl: ttl) else { return [] }
        return sections(from: evidence)
    }

    /// The bridge only refreshes while a Claude Code session is running, so between sessions the
    /// snapshot ages out of the freshness window even though its 5h/7d allowances are still open.
    /// Surfaces that would rather show an aging number than nothing use this and label it stale.
    public static func lastKnownRateLimitSections(evidence: ClaudeLiveEvidence?) -> [RateLimitDisplaySection] {
        guard let evidence else { return [] }
        return sections(from: evidence)
    }

    private static func sections(from evidence: ClaudeLiveEvidence) -> [RateLimitDisplaySection] {
        let snapshot = evidence.snapshot
        let rows = [
            row(
                id: sessionRowID,
                title: L10n.tr("limit.claude.session"),
                windowMinutes: 300,
                window: snapshot.fiveHour
            ),
            row(
                id: allModelsRowID,
                title: L10n.tr("limit.claude.all_models"),
                windowMinutes: 10_080,
                window: snapshot.sevenDay
            ),
            row(
                id: topModelRowID,
                title: L10n.tr("limit.claude.top_model"),
                windowMinutes: 10_080,
                window: snapshot.sevenDayTopModel
            ),
        ].compactMap { $0 }

        guard !rows.isEmpty else { return [] }
        return [RateLimitDisplaySection(id: "claude.live", title: "Claude Code", rows: rows)]
    }

    private static func row(
        id: String,
        title: String,
        windowMinutes: Int64,
        window: ClaudeStatuslineBridgeSnapshot.Window?
    ) -> RateLimitDisplayRow? {
        guard let window, let value = window.usedPercentage, value.isFinite else { return nil }
        let usedPercent = min(max(Int(value.rounded()), 0), 100)
        let resetDate = window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return RateLimitDisplayRow(
            id: id,
            title: title,
            usedPercent: usedPercent,
            resetText: resetDate.map { RateLimitResetFormatter.expandedText(for: $0) },
            resetDate: resetDate,
            windowMinutes: windowMinutes
        )
    }
}
