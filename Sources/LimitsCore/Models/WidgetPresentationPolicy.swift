import Foundation
import LimitsShared

public enum WidgetPresentationPolicy {
    public static func limitSnapshots(
        from sections: [RateLimitDisplaySection],
        now: Date = .now
    ) -> [LimitsWidgetLimitSnapshot] {
        sections.flatMap { section in
            section.rows.map { row in
                let resetIsStale = row.resetDate.map { $0 <= now } ?? false
                return LimitsWidgetLimitSnapshot(
                    id: "\(section.id).\(row.id)",
                    title: row.title,
                    remainingPercent: resetIsStale ? nil : row.remainingPercent,
                    resetDate: row.resetDate
                )
            }
        }
    }

    public static func freshUntil(
        observedAt: Date?,
        limits: [LimitsWidgetLimitSnapshot]
    ) -> Date? {
        LimitsFreshnessPolicy.freshUntil(
            observedAt: observedAt,
            limitResetDates: limits.compactMap(\.resetDate),
            ttl: LimitsFreshnessPolicy.defaultTTL
        )
    }
}
