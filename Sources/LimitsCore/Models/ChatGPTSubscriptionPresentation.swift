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
        switch planType.lowercased() {
        case "free":
            return priced("ChatGPT Free", dollars: 0)
        case "go":
            return priced("ChatGPT Go", dollars: 8)
        case "plus":
            return priced("ChatGPT Plus", dollars: 20)
        case "prolite":
            return priced("ChatGPT Pro 5×", dollars: 100)
        case "pro":
            return priced("ChatGPT Pro 20×", dollars: 200)
        case "team":
            return ChatGPTPlanPresentation(title: "ChatGPT Team", monthlyPrice: nil)
        case "self_serve_business_prolite", "self_serve_business_usage_based", "business":
            return ChatGPTPlanPresentation(title: "ChatGPT Business", monthlyPrice: nil)
        case "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based", "enterprise":
            return ChatGPTPlanPresentation(title: "ChatGPT Enterprise", monthlyPrice: nil)
        case "edu":
            return ChatGPTPlanPresentation(title: "ChatGPT Edu", monthlyPrice: nil)
        case "unknown":
            return ChatGPTPlanPresentation(title: L10n.tr("plan.unknown"), monthlyPrice: nil)
        default:
            return ChatGPTPlanPresentation(title: planType, monthlyPrice: nil)
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
