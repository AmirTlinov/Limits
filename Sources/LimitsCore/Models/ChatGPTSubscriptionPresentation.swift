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

    public static func periodText(
        for period: ChatGPTSubscriptionPeriod?,
        now: Date = .now
    ) -> String? {
        guard let activeUntil = period?.activeUntil else { return nil }
        let formatted = L10n.localizedDateTime(activeUntil)
        if activeUntil > now {
            return L10n.tr("subscription.current_period_until", formatted)
        }
        return L10n.tr("subscription.last_period_until", formatted)
    }

    private static func priced(_ title: String, dollars: Int) -> ChatGPTPlanPresentation {
        ChatGPTPlanPresentation(
            title: title,
            monthlyPrice: L10n.tr("subscription.price.monthly", dollars)
        )
    }
}
