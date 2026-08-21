import Foundation
import LimitsShared

public enum CodexAnalyticsSurfacePresentation {
    public static func widgetSummary(from snapshot: CodexInsightsSnapshot) -> CodexAnalyticsSummary {
        let risk = snapshot.nearestRiskAccountID.flatMap { id in snapshot.accounts.first { $0.id == id } }
            ?? snapshot.accounts.min {
                ($0.forecast.remainingPercent ?? 101) < ($1.forecast.remainingPercent ?? 101)
            }
        return CodexAnalyticsSummary(
            accountLabel: risk?.label,
            planTitle: risk?.planTitle,
            forecastState: widgetState(risk?.forecast.state),
            predictedExhaustionAt: risk?.forecast.predictedExhaustionAt,
            resetAt: risk?.forecast.resetAt,
            remainingPercent: risk?.forecast.remainingPercent,
            forecastObservedAt: risk?.forecast.latestObservationAt,
            weeklyTokens: snapshot.totals.usage.totalTokens,
            weeklyCredits: snapshot.totals.credits
        )
    }

    public static func trayForecast(
        from snapshot: CodexInsightsSnapshot,
        currentAccountID: String?,
        now: Date = .now
    ) -> String? {
        guard let currentAccountID,
              let account = snapshot.accounts.first(where: { $0.id == currentAccountID }) else { return nil }
        return CodexInsightsTextPresentation.forecast(account.forecast, now: now)
    }

    private static func widgetState(_ state: LimitBurnForecastState?) -> LimitsWidgetForecastState {
        switch state {
        case .exhaustsBeforeReset: .exhaustsBeforeReset
        case .lastsUntilReset, .stable: .lastsUntilReset
        case .stale: .stale
        case .collecting, nil: .collecting
        }
    }
}
