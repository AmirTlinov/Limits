import Foundation

public enum CodexAccountValidationPolicy {
    public static func makeAccount(
        id: UUID,
        label: String,
        createdAt: Date,
        from result: AccountValidationResult,
        observedAt: Date
    ) -> StoredAccount {
        let account = StoredAccount(
            id: id,
            label: label,
            email: result.email,
            accountId: result.identity.accountId,
            planType: result.planType,
            createdAt: createdAt,
            updatedAt: observedAt,
            lastValidatedAt: nil,
            status: .unknown,
            statusMessage: nil,
            lastRateLimit: nil,
            lastRateLimitsByLimitId: nil,
            authFingerprint: result.authFingerprint,
            keychainAccount: ""
        )
        return applying(result, to: account, observedAt: observedAt)
    }

    public static func applying(
        _ result: AccountValidationResult,
        to account: StoredAccount,
        observedAt: Date
    ) -> StoredAccount {
        var updated = account
        let previousPlanType = updated.planType
        let limitsWereObserved = result.rateLimitError == nil

        updated.email = result.email
        updated.accountId = result.identity.accountId
        updated.planType = result.planType
        updated.authFingerprint = result.authFingerprint
        updated.updatedAt = observedAt
        updated.lastValidatedAt = observedAt

        if limitsWereObserved {
            updated.lastRateLimit = result.rateLimit
            updated.lastRateLimitsByLimitId = result.rateLimitsByLimitId
            updated.lastRateLimitObservedAt = observedAt
        }

        if let subscriptionPeriod = result.subscriptionPeriod {
            updated.subscriptionPeriod = subscriptionPeriod
        } else if previousPlanType != result.planType {
            updated.subscriptionPeriod = nil
        }

        updated.status = limitsWereObserved ? status(for: result) : .ok
        updated.statusMessage = result.rateLimitError ?? statusMessage(for: result)
        return updated
    }

    private static func status(for result: AccountValidationResult) -> AccountStatus {
        let snapshots = result.rateLimitsByLimitId.map { Array($0.values) } ?? []
        if result.rateLimit?.isReached == true || snapshots.contains(where: { $0.isReached }) {
            return .limitReached
        }
        return .ok
    }

    private static func statusMessage(for result: AccountValidationResult) -> String? {
        let snapshots = [result.rateLimit]
            .compactMap { $0 }
            + (result.rateLimitsByLimitId?.keys.sorted().compactMap { result.rateLimitsByLimitId?[$0] } ?? [])

        if let reachedType = snapshots.compactMap(\.rateLimitReachedType).first {
            return reachedType.replacingOccurrences(of: "_", with: " ").capitalized
        }
        if let usage = snapshots.compactMap({ $0.compactUsageSummary() }).first {
            return usage
        }
        return nil
    }
}
