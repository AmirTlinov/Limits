import Foundation
import LimitsShared

public enum CodexInsightsTextPresentation {
    public static func periodTitle(_ period: CodexUsagePeriod) -> String {
        switch period {
        case .currentWeek: L10n.tr("insights.period.week")
        case .last30Days: L10n.tr("insights.period.30_days")
        case .last6Months: L10n.tr("insights.period.6_months")
        case .lastYear: L10n.tr("insights.period.year")
        case .custom: L10n.tr("insights.period.custom")
        case .all: L10n.tr("insights.period.all")
        }
    }

    public static func forecast(_ forecast: LimitBurnForecast, now: Date = .now) -> String {
        switch forecast.state {
        case .collecting:
            return L10n.tr("insights.forecast.collecting")
        case .stale:
            return L10n.tr("insights.forecast.stale")
        case .lastsUntilReset:
            return L10n.tr("insights.forecast.lasts")
        case .stable:
            return L10n.tr("insights.forecast.stable")
        case .exhaustsBeforeReset:
            guard let date = forecast.predictedExhaustionAt else {
                return L10n.tr("insights.forecast.exhausted")
            }
            if date <= now { return L10n.tr("insights.forecast.exhausted") }
            let countdown = L10n.countdown(until: Int64(date.timeIntervalSince1970), now: now)
                ?? L10n.tr("subscription.date_unavailable")
            return L10n.tr("insights.forecast.exhausts_in", countdown)
        }
    }

    public static func reset(_ forecast: LimitBurnForecast, now: Date = .now) -> String? {
        forecast.resetAt.map { L10n.resetExpandedText(for: $0, now: now) }
    }

    public static func modelTitle(_ modelID: String) -> String {
        let value = modelID.lowercased()
        if value.contains("sol") || value == "gpt-5.6" { return "Sol" }
        if value.contains("terra") { return "Terra" }
        if value.contains("luna") { return "Luna" }
        if value == "unattributed" { return L10n.tr("insights.model.unknown") }
        return modelID
    }

    public static func compactTokens(_ tokens: Int64) -> String {
        let magnitude: Decimal
        let suffix: String
        if tokens >= 1_000_000_000 {
            magnitude = Decimal(tokens) / 1_000_000_000
            suffix = L10n.tr("insights.tokens.billions_suffix")
        } else if tokens >= 1_000_000 {
            magnitude = Decimal(tokens) / 1_000_000
            suffix = L10n.tr("insights.tokens.millions_suffix")
        } else if tokens >= 1_000 {
            magnitude = Decimal(tokens) / 1_000
            suffix = L10n.tr("insights.tokens.thousands_suffix")
        } else {
            return L10n.localizedInteger(tokens)
        }
        return "\(L10n.localizedDecimal(magnitude, maximumFractionDigits: 1))\(suffix)"
    }

    public static func priceMetricTitle(_ metric: OpenAIPriceMetric) -> String {
        switch metric {
        case .creditsFastMultiplier:
            return L10n.tr("insights.price_change.metric.creditsFastMultiplier")
        case .apiLongInput, .apiLongCachedInput, .apiLongCacheWrite, .apiLongOutput:
            return L10n.tr("insights.price_change.metric.long", basePriceMetricTitle(metric))
        case .apiFastInput, .apiFastCachedInput, .apiFastCacheWrite, .apiFastOutput:
            return L10n.tr("insights.price_change.metric.fast", basePriceMetricTitle(metric))
        case .apiFastLongInput, .apiFastLongCachedInput, .apiFastLongCacheWrite, .apiFastLongOutput:
            return L10n.tr("insights.price_change.metric.fast_long", basePriceMetricTitle(metric))
        default:
            return basePriceMetricTitle(metric)
        }
    }

    public static func priceValue(_ value: Decimal, metric: OpenAIPriceMetric) -> String {
        if metric.usesMultiplier {
            return L10n.tr(
                "insights.price_change.multiplier",
                L10n.localizedDecimal(value, maximumFractionDigits: 3)
            )
        }
        if metric.usesUSD {
            return L10n.tr("insights.price_change.usd_per_million", L10n.localizedCurrencyUSD(value))
        }
        return L10n.tr(
            "insights.price_change.credits_per_million",
            L10n.localizedDecimal(value, maximumFractionDigits: 3)
        )
    }

    private static func basePriceMetricTitle(_ metric: OpenAIPriceMetric) -> String {
        let base: OpenAIPriceMetric = switch metric {
        case .apiLongInput, .apiFastInput, .apiFastLongInput: .apiInput
        case .apiLongCachedInput, .apiFastCachedInput, .apiFastLongCachedInput: .apiCachedInput
        case .apiLongCacheWrite, .apiFastCacheWrite, .apiFastLongCacheWrite: .apiCacheWrite
        case .apiLongOutput, .apiFastOutput, .apiFastLongOutput: .apiOutput
        default: metric
        }
        return L10n.tr("insights.price_change.metric.\(base.rawValue)")
    }
}
