import Foundation
import LimitsShared

public enum LimitBurnEstimator {
    public static let minimumObservationCount = 3
    public static let minimumCoverage: TimeInterval = 30 * 60
    public static let minimumMovement = 2

    public static func forecast(
        observations: [CodexLimitObservation],
        now: Date = .now,
        staleAfter: TimeInterval = LimitsFreshnessPolicy.defaultTTL
    ) -> LimitBurnForecast {
        guard let series = weeklySeries(from: observations), let latest = series.last else {
            return LimitBurnForecast(
                state: .collecting,
                predictedExhaustionAt: nil,
                resetAt: nil,
                remainingPercent: nil,
                percentPerHour: nil,
                latestObservationAt: nil
            )
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

    public static func weeklySeries(from observations: [CodexLimitObservation]) -> [CodexLimitObservation]? {
        let weekly = observations.filter { observation in
            guard let minutes = observation.windowDurationMinutes else { return false }
            return minutes >= 6 * 24 * 60
        }
        guard !weekly.isEmpty else { return nil }
        let grouped = Dictionary(grouping: weekly) {
            "\($0.limitID)|\($0.window.rawValue)|\(Int64($0.resetsAt?.timeIntervalSince1970 ?? -1))"
        }
        return grouped.values
            .map { values in values.sorted { $0.observedAt < $1.observedAt } }
            .max { lhs, rhs in
                let lhsDate = lhs.last?.observedAt ?? .distantPast
                let rhsDate = rhs.last?.observedAt ?? .distantPast
                return lhsDate < rhsDate
            }
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
