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
        updated.email = result.email
        updated.accountId = result.identity.accountId
        updated.planType = result.planType
        updated.authFingerprint = result.authFingerprint
        updated.updatedAt = observedAt
        updated.lastValidatedAt = observedAt

        if let subscriptionPeriod = result.subscriptionPeriod {
            updated.subscriptionPeriod = subscriptionPeriod
        } else if previousPlanType != result.planType {
            updated.subscriptionPeriod = nil
        }

        // account/read is the authorization contract. Limits and usage are
        // independent observations and therefore cannot make the identity invalid.
        updated.status = .ok
        updated.statusMessage = nil
        return updated
    }
}
