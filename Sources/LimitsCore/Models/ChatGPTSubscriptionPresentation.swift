import Foundation
import LimitsShared

public struct ChatGPTPlanPresentation: Hashable, Sendable {
    public let title: String
    public let monthlyPrice: String?

    public init(title: String, monthlyPrice: String?) {
        self.title = title
        self.monthlyPrice = monthlyPrice
    }

    public var summary: String {
        [title, monthlyPrice].compactMap { $0 }.joined(separator: " · ")
    }
}

public struct ChatGPTSubscriptionCyclePresentation: Hashable, Sendable {
    public let remainingProgress: Double?
    public let countdownText: String
    public let paymentDateText: String
    public let isExpired: Bool

    public init(
        remainingProgress: Double?,
        countdownText: String,
        paymentDateText: String,
        isExpired: Bool
    ) {
        self.remainingProgress = remainingProgress
        self.countdownText = countdownText
        self.paymentDateText = paymentDateText
        self.isExpired = isExpired
    }
}

public enum ChatGPTSubscriptionPresentationPolicy {
    public static func plan(for planType: String) -> ChatGPTPlanPresentation {
        let definition = definition(for: planType)
        guard let dollars = definition.monthlyPriceUSD else {
            return ChatGPTPlanPresentation(title: definition.title, monthlyPrice: nil)
        }
        return priced(definition.title, dollars: dollars)
    }

    public static func monthlyPriceUSD(for planType: String) -> Decimal? {
        definition(for: planType).monthlyPriceUSD.map { Decimal($0) }
    }

    private static func definition(for planType: String) -> (title: String, monthlyPriceUSD: Int?) {
        switch planType.lowercased() {
        case "free":
            return ("ChatGPT Free", 0)
        case "go":
            return ("ChatGPT Go", 8)
        case "plus":
            return ("ChatGPT Plus", 20)
        case "prolite":
            return ("ChatGPT Pro 5×", 100)
        case "pro":
            return ("ChatGPT Pro 20×", 200)
        case "team":
            return ("ChatGPT Team", nil)
        case "self_serve_business_prolite", "self_serve_business_usage_based", "business":
            return ("ChatGPT Business", nil)
        case "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based", "enterprise":
            return ("ChatGPT Enterprise", nil)
        case "edu":
            return ("ChatGPT Edu", nil)
        case "unknown":
            return (L10n.tr("plan.unknown"), nil)
        default:
            return (planType, nil)
        }
    }

    public static func cycle(
        for period: ChatGPTSubscriptionPeriod?,
        now: Date = .now
    ) -> ChatGPTSubscriptionCyclePresentation? {
        guard let activeUntil = period?.activeUntil else { return nil }
        let isExpired = activeUntil <= now
        let countdownText: String
        let paymentDateText: String

        if isExpired {
            countdownText = L10n.tr("subscription.period_ended")
            paymentDateText = L10n.tr("subscription.ended_at", L10n.shortDayTime(activeUntil))
        } else {
            let timestamp = Int64(activeUntil.timeIntervalSince1970)
            countdownText = L10n.countdown(until: timestamp, now: now)
                ?? L10n.tr("subscription.date_unavailable")
            paymentDateText = L10n.tr("subscription.payment_at", L10n.shortDayTime(activeUntil))
        }

        return ChatGPTSubscriptionCyclePresentation(
            remainingProgress: remainingProgress(
                from: period?.activeStart,
                until: activeUntil,
                now: now
            ),
            countdownText: countdownText,
            paymentDateText: paymentDateText,
            isExpired: isExpired
        )
    }

    private static func priced(_ title: String, dollars: Int) -> ChatGPTPlanPresentation {
        ChatGPTPlanPresentation(
            title: title,
            monthlyPrice: L10n.tr("subscription.price.monthly", dollars)
        )
    }

    private static func remainingProgress(from activeStart: Date?, until activeUntil: Date, now: Date) -> Double? {
        guard let activeStart, activeUntil > activeStart else { return nil }
        let duration = activeUntil.timeIntervalSince(activeStart)
        let remaining = activeUntil.timeIntervalSince(now)
        return min(max(remaining / duration, 0), 1)
    }
}
