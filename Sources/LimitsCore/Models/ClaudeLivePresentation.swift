import Foundation
import LimitsShared

public enum ClaudeLivePresentation {
    public static func rateLimitSections(
        evidence: ClaudeLiveEvidence?,
        now: Date = .now,
        ttl: TimeInterval = LimitsFreshnessPolicy.defaultTTL
    ) -> [RateLimitDisplaySection] {
        guard let evidence, LimitsFreshnessPolicy.isFresh(observedAt: evidence.snapshotAt, at: now, ttl: ttl) else { return [] }
        var rows: [RateLimitDisplayRow] = []
        if let row = row(id: "claude.five_hour", title: L10n.tr("limit.five_hour"), window: evidence.snapshot.fiveHour) {
            rows.append(row)
        }
        if let row = row(id: "claude.seven_day", title: L10n.tr("limit.weekly"), window: evidence.snapshot.sevenDay) {
            rows.append(row)
        }
        guard !rows.isEmpty else { return [] }
        return [RateLimitDisplaySection(id: "claude.live", title: "Claude Code", rows: rows)]
    }

    private static func row(
        id: String,
        title: String,
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
            resetDate: resetDate
        )
    }
}
