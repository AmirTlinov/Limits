import Foundation
import LimitsShared
import Testing
@testable import LimitsCore

@Test func forecastPredictsExhaustionBeforeResetFromRobustWeeklySlope() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let reset = start.addingTimeInterval(5 * 60 * 60)
    let observations = [
        weeklyObservation(at: start, used: 10, reset: reset),
        weeklyObservation(at: start.addingTimeInterval(30 * 60), used: 20, reset: reset),
        weeklyObservation(at: start.addingTimeInterval(60 * 60), used: 30, reset: reset),
    ]

    let forecast = LimitBurnEstimator.forecast(observations: observations, now: start.addingTimeInterval(60 * 60))

    #expect(forecast.state == .exhaustsBeforeReset)
    #expect(forecast.remainingPercent == 70)
    #expect(abs((forecast.percentPerHour ?? 0) - 20) < 0.000_001)
    #expect(forecast.predictedExhaustionAt == start.addingTimeInterval(4.5 * 60 * 60))
}

@Test func roundedPercentagesStillProduceForecastAfterTwoPointMovement() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let reset = start.addingTimeInterval(20 * 60 * 60)
    let observations = [
        weeklyObservation(at: start, used: 10, reset: reset),
        weeklyObservation(at: start.addingTimeInterval(15 * 60), used: 10, reset: reset),
        weeklyObservation(at: start.addingTimeInterval(30 * 60), used: 12, reset: reset),
    ]

    let forecast = LimitBurnEstimator.forecast(observations: observations, now: start.addingTimeInterval(30 * 60))

    #expect(forecast.state == .lastsUntilReset)
    #expect(abs((forecast.percentPerHour ?? 0) - 4) < 0.000_001)
}

@Test func crossedResetStartsAnewCollectionState() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let reset = start.addingTimeInterval(60 * 60)
    let forecast = LimitBurnEstimator.forecast(
        observations: [
            weeklyObservation(at: start, used: 80, reset: reset),
            weeklyObservation(at: start.addingTimeInterval(30 * 60), used: 90, reset: reset),
            weeklyObservation(at: start.addingTimeInterval(50 * 60), used: 95, reset: reset),
        ],
        now: reset.addingTimeInterval(1)
    )

    #expect(forecast.state == .collecting)
    #expect(forecast.remainingPercent == nil)
    #expect(forecast.predictedExhaustionAt == nil)
}

@Test func forecastRequiresThreeObservationsThirtyMinutesAndTwoPercentMovement() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let reset = start.addingTimeInterval(10 * 60 * 60)

    #expect(LimitBurnEstimator.forecast(
        observations: [
            weeklyObservation(at: start, used: 10, reset: reset),
            weeklyObservation(at: start.addingTimeInterval(31 * 60), used: 20, reset: reset),
        ],
        now: start.addingTimeInterval(31 * 60)
    ).state == .collecting)
    #expect(LimitBurnEstimator.forecast(
        observations: [
            weeklyObservation(at: start, used: 10, reset: reset),
            weeklyObservation(at: start.addingTimeInterval(10 * 60), used: 11, reset: reset),
            weeklyObservation(at: start.addingTimeInterval(20 * 60), used: 12, reset: reset),
        ],
        now: start.addingTimeInterval(20 * 60)
    ).state == .collecting)
    #expect(LimitBurnEstimator.forecast(
        observations: [
            weeklyObservation(at: start, used: 10, reset: reset),
            weeklyObservation(at: start.addingTimeInterval(15 * 60), used: 10, reset: reset),
            weeklyObservation(at: start.addingTimeInterval(30 * 60), used: 11, reset: reset),
        ],
        now: start.addingTimeInterval(30 * 60)
    ).state == .collecting)
}

@Test func oldWeeklyEvidenceIsMarkedStale() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let reset = start.addingTimeInterval(10 * 60 * 60)
    let observations = [
        weeklyObservation(at: start, used: 10, reset: reset),
        weeklyObservation(at: start.addingTimeInterval(30 * 60), used: 20, reset: reset),
        weeklyObservation(at: start.addingTimeInterval(60 * 60), used: 30, reset: reset),
    ]

    let forecast = LimitBurnEstimator.forecast(
        observations: observations,
        now: start.addingTimeInterval(3 * 60 * 60),
        staleAfter: 60 * 60
    )
    #expect(forecast.state == .stale)
}

@Test func weeklyForecastUsesTheSharedFifteenMinuteSurfaceFreshness() {
    let observedAt = Date(timeIntervalSince1970: 1_000_000)
    let reset = observedAt.addingTimeInterval(10 * 60 * 60)
    let forecast = LimitBurnEstimator.forecast(
        observations: [weeklyObservation(at: observedAt, used: 20, reset: reset)],
        now: observedAt.addingTimeInterval(LimitsFreshnessPolicy.defaultTTL + 1)
    )

    #expect(forecast.state == .stale)
    #expect(forecast.latestObservationAt == observedAt)
}

@Test func externalUsageJumpContributesToTheServerBurnForecast() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let reset = start.addingTimeInterval(24 * 60 * 60)
    let forecast = LimitBurnEstimator.forecast(
        observations: [
            weeklyObservation(at: start, used: 10, reset: reset),
            weeklyObservation(at: start.addingTimeInterval(30 * 60), used: 12, reset: reset),
            weeklyObservation(at: start.addingTimeInterval(60 * 60), used: 42, reset: reset),
        ],
        now: start.addingTimeInterval(60 * 60)
    )

    #expect(forecast.state == .exhaustsBeforeReset)
    #expect(forecast.percentPerHour != nil)
    #expect(forecast.latestObservationAt == start.addingTimeInterval(60 * 60))
}

private func weeklyObservation(at date: Date, used: Int, reset: Date) -> CodexLimitObservation {
    CodexLimitObservation(
        accountID: "acct",
        limitID: "codex",
        window: .secondary,
        observedAt: date,
        usedPercent: used,
        resetsAt: reset,
        windowDurationMinutes: 10_080
    )
}
