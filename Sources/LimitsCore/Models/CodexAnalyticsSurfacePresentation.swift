import Foundation
import LimitsShared

public enum CodexAnalyticsSurfacePresentation {
    public static func widgetSummary(from snapshot: CodexInsightsSnapshot) -> CodexAnalyticsSummary {
        let risk = CodexAnalyticsSelection.quota(in: snapshot)
        return CodexAnalyticsSummary(
            accountLabel: risk?.account.label,
            planTitle: risk?.account.planTitle,
            quotaTitle: risk?.quota.title,
            forecastState: widgetState(risk?.quota.forecast.state),
            predictedExhaustionAt: risk?.quota.forecast.predictedExhaustionAt,
            resetAt: risk?.quota.forecast.resetAt,
            remainingPercent: risk?.quota.forecast.remainingPercent,
            forecastObservedAt: risk?.quota.forecast.latestObservationAt,
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
              let account = snapshot.accounts.first(where: { $0.id == currentAccountID }),
              let quota = account.riskiestQuotaForecast else { return nil }
        return "\(quota.title) · \(CodexInsightsTextPresentation.forecast(quota.forecast, now: now))"
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
