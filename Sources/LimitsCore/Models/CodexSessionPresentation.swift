import Foundation
import LimitsShared

public struct CodexSessionProbe: Sendable {
    public let fingerprint: String
    public let email: String
    public let planType: String
    public let rateLimit: RateLimitSnapshotModel?
    public let rateLimitsByLimitId: [String: RateLimitSnapshotModel]?
    public let validatedAt: Date
    public let rateLimitError: String?
    public let rateLimitObservedAt: Date?
    public let subscriptionPeriod: ChatGPTSubscriptionPeriod?

    public init(fingerprint: String, email: String, planType: String, rateLimit: RateLimitSnapshotModel?, rateLimitsByLimitId: [String: RateLimitSnapshotModel]?, validatedAt: Date, rateLimitError: String? = nil, rateLimitObservedAt: Date? = nil, subscriptionPeriod: ChatGPTSubscriptionPeriod? = nil) {
        self.fingerprint = fingerprint
        self.email = email
        self.planType = planType
        self.rateLimit = rateLimit
        self.rateLimitsByLimitId = rateLimitsByLimitId
        self.validatedAt = validatedAt
        self.rateLimitError = rateLimitError
        self.rateLimitObservedAt = rateLimitObservedAt
        self.subscriptionPeriod = subscriptionPeriod
    }

    public var limitsObservedAt: Date? {
        rateLimitObservedAt ?? (rateLimitError == nil ? validatedAt : nil)
    }
}

public enum CodexSessionPresentation {
    public static func probeNote(for message: String) -> String {
        let lowered = message.lowercased()
        if lowered.contains("unauthorized") || lowered.contains("401") || lowered.contains("auth") || lowered.contains("login") {
            return L10n.tr("cli.current_reauth_needed")
        }
        return L10n.tr("cli.live_update_failed")
    }

    public static func panelSummary(
        probe: CodexSessionProbe?,
        probeError: String? = nil,
        now: Date
    ) -> String? {
        guard probeError == nil, isFresh(probe, now: now) else { return nil }
        return probe?.rateLimit?.panelSummary()
    }

    public static func rateLimitSections(
        probe: CodexSessionProbe?,
        probeError: String? = nil,
        now: Date
    ) -> [RateLimitDisplaySection] {
        guard probeError == nil, isFresh(probe, now: now) else { return [] }
        return RateLimitDisplayBuilder.makeSections(
            primary: probe?.rateLimit,
            byLimitId: probe?.rateLimitsByLimitId,
            excludingExpiredRowsAt: now
        )
    }

    private static func isFresh(_ probe: CodexSessionProbe?, now: Date) -> Bool {
        guard let probe else { return false }
        return LimitsFreshnessPolicy.isFresh(observedAt: probe.limitsObservedAt, at: now)
    }
}
