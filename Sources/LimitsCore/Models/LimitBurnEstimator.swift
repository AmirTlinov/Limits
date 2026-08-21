import Foundation
import LimitsShared

public enum LimitBurnEstimator {
    public static let minimumObservationCount = 3
    public static let minimumCoverage: TimeInterval = 30 * 60
    public static let minimumMovement = 2

    /// Estimates one quota cycle. Callers give observations for exactly one
    /// `CodexQuotaKey`; quota selection belongs to `CodexQuotaAnalytics`.
    public static func forecast(
        observations: [CodexLimitObservation],
        now: Date = .now,
        staleAfter: TimeInterval = LimitsFreshnessPolicy.defaultTTL
    ) -> LimitBurnForecast {
        guard let series = currentCycle(from: observations), let latest = series.last else {
            return collectingForecast()
        }
        let remaining = max(0, 100 - latest.usedPercent)
        if now.timeIntervalSince(latest.observedAt) < 0 || now.timeIntervalSince(latest.observedAt) > staleAfter {
            return result(.stale, latest: latest, remaining: remaining)
        }
        if let reset = latest.resetsAt, reset <= now {
            return LimitBurnForecast(
                state: .collecting,
                predictedExhaustionAt: nil,
                resetAt: reset,
                remainingPercent: nil,
                percentPerHour: nil,
                latestObservationAt: latest.observedAt
            )
        }
        if latest.usedPercent >= 100 {
            return LimitBurnForecast(
                state: .exhaustsBeforeReset,
                predictedExhaustionAt: latest.observedAt,
                resetAt: latest.resetsAt,
                remainingPercent: 0,
                percentPerHour: nil,
                latestObservationAt: latest.observedAt
            )
        }
        guard series.count >= minimumObservationCount,
              let first = series.first,
              latest.observedAt.timeIntervalSince(first.observedAt) >= minimumCoverage,
              latest.usedPercent - first.usedPercent >= minimumMovement else {
            return result(.collecting, latest: latest, remaining: remaining)
        }

        let slopes = pairwiseSlopes(series).sorted()
        guard let slope = median(slopes), slope > 0 else {
            return result(.collecting, latest: latest, remaining: remaining)
        }
        let exhaustion = latest.observedAt.addingTimeInterval(Double(remaining) / slope * 60 * 60)
        let state: LimitBurnForecastState
        if let reset = latest.resetsAt {
            state = exhaustion < reset ? .exhaustsBeforeReset : .lastsUntilReset
        } else {
            state = .stable
        }
        return LimitBurnForecast(
            state: state,
            predictedExhaustionAt: exhaustion,
            resetAt: latest.resetsAt,
            remainingPercent: remaining,
            percentPerHour: slope,
            latestObservationAt: latest.observedAt
        )
    }

    /// Returns only the latest reset cycle. Equal timestamps are collapsed by
    /// value, so input order and dictionary iteration cannot change the answer.
    public static func currentCycle(from observations: [CodexLimitObservation]) -> [CodexLimitObservation]? {
        let weekly = observations.filter { ($0.windowDurationMinutes ?? 0) >= 6 * 24 * 60 }
        guard !weekly.isEmpty else { return nil }

        let normalized = Dictionary(grouping: weekly, by: \.observedAt)
            .compactMap { _, values in values.max(by: deterministicValueOrder) }
            .sorted(by: deterministicTimeOrder)
        guard !normalized.isEmpty else { return nil }

        var cycleStart = normalized.startIndex
        for index in normalized.indices.dropFirst() {
            let previous = normalized[normalized.index(before: index)]
            let current = normalized[index]
            if current.usedPercent < previous.usedPercent || current.resetsAt != previous.resetsAt {
                cycleStart = index
            }
        }
        return Array(normalized[cycleStart...])
    }

    private static func deterministicValueOrder(
        _ lhs: CodexLimitObservation,
        _ rhs: CodexLimitObservation
    ) -> Bool {
        if lhs.usedPercent != rhs.usedPercent { return lhs.usedPercent < rhs.usedPercent }
        if lhs.resetsAt != rhs.resetsAt {
            return (lhs.resetsAt ?? .distantPast) < (rhs.resetsAt ?? .distantPast)
        }
        if lhs.limitID != rhs.limitID { return lhs.limitID < rhs.limitID }
        return lhs.window.rawValue < rhs.window.rawValue
    }

    private static func deterministicTimeOrder(
        _ lhs: CodexLimitObservation,
        _ rhs: CodexLimitObservation
    ) -> Bool {
        if lhs.observedAt != rhs.observedAt { return lhs.observedAt < rhs.observedAt }
        return deterministicValueOrder(lhs, rhs)
    }

    private static func pairwiseSlopes(_ observations: [CodexLimitObservation]) -> [Double] {
        var result: [Double] = []
        for left in observations.indices {
            for right in observations.indices where right > left {
                let seconds = observations[right].observedAt.timeIntervalSince(observations[left].observedAt)
                let movement = observations[right].usedPercent - observations[left].usedPercent
                guard seconds > 0, movement >= 0 else { continue }
                result.append(Double(movement) / seconds * 60 * 60)
            }
        }
        return result
    }

    private static func median(_ sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func collectingForecast() -> LimitBurnForecast {
        LimitBurnForecast(
            state: .collecting,
            predictedExhaustionAt: nil,
            resetAt: nil,
            remainingPercent: nil,
            percentPerHour: nil,
            latestObservationAt: nil
        )
    }

    private static func result(
        _ state: LimitBurnForecastState,
        latest: CodexLimitObservation,
        remaining: Int
    ) -> LimitBurnForecast {
        LimitBurnForecast(
            state: state,
            predictedExhaustionAt: nil,
            resetAt: latest.resetsAt,
            remainingPercent: remaining,
            percentPerHour: nil,
            latestObservationAt: latest.observedAt
        )
    }
}

/// Owns the mapping from server quota identities to independent forecasts.
public enum CodexQuotaAnalytics {
    public static let weeklyWindowMinutes: Int64 = 7 * 24 * 60

    public static func forecasts(
        observations: [CodexLimitObservation],
        latestLimits: CodexRateLimitsSnapshot?,
        now: Date = .now
    ) -> [CodexQuotaForecast] {
        let grouped = Dictionary(grouping: observations.filter(isWeekly)) {
            CodexQuotaKey(limitID: $0.limitID, windowKind: $0.window)
        }
        return grouped.map { key, series in
            CodexQuotaForecast(
                key: key,
                title: quotaTitle(for: key.limitID, latestLimits: latestLimits),
                isBaseQuota: key.limitID == "codex",
                forecast: LimitBurnEstimator.forecast(observations: series, now: now)
            )
        }
        .sorted(by: stableQuotaOrder)
    }

    public static func baseUsageWindow(
        observations: [CodexLimitObservation],
        now: Date
    ) -> CodexUsageWindow {
        let baseWeekly = observations.filter { $0.limitID == "codex" && isWeekly($0) }
        if let latest = LimitBurnEstimator.currentCycle(from: baseWeekly)?.last,
           let reset = latest.resetsAt,
           let duration = latest.windowDurationMinutes,
           reset > now {
            return CodexUsageWindow(
                start: reset.addingTimeInterval(-TimeInterval(duration * 60)),
                end: reset
            )
        }
        return CodexUsageWindow(
            start: now.addingTimeInterval(-TimeInterval(weeklyWindowMinutes * 60)),
            end: now.addingTimeInterval(1)
        )
    }

    private static func isWeekly(_ observation: CodexLimitObservation) -> Bool {
        (observation.windowDurationMinutes ?? 0) >= 6 * 24 * 60
    }

    private static func quotaTitle(
        for limitID: String,
        latestLimits: CodexRateLimitsSnapshot?
    ) -> String {
        let snapshot = latestLimits?.byLimitID?[limitID]
            ?? ((latestLimits?.primary?.limitId ?? "codex") == limitID ? latestLimits?.primary : nil)
        if let title = snapshot?.limitName?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return limitID == "codex" ? "Codex" : limitID
    }

    private static func stableQuotaOrder(_ lhs: CodexQuotaForecast, _ rhs: CodexQuotaForecast) -> Bool {
        if lhs.isBaseQuota != rhs.isBaseQuota { return lhs.isBaseQuota }
        if lhs.title != rhs.title { return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending }
        if lhs.key.limitID != rhs.key.limitID { return lhs.key.limitID < rhs.key.limitID }
        return lhs.key.windowKind.rawValue < rhs.key.windowKind.rawValue
    }
}
