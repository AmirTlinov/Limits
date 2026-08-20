import Foundation
import Testing
@testable import LimitsCore

@MainActor
@Test func reauthenticationReplacesRequestedRecordOnlyForSameStableIdentity() {
    let requested = makeReauthenticationAccount(accountID: "acct_requested", fingerprint: "old")
    let result = makeReauthenticationResult(accountID: "acct_requested", fingerprint: "rotated")

    #expect(
        AccountResolution.reauthenticationTarget(requested: requested, result: result, accounts: [requested])
            == .requestedAccount(requested.id)
    )
}

@MainActor
@Test func reauthenticationUpdatesOtherExistingAccountWithoutOverwritingRequestedRecord() {
    let requested = makeReauthenticationAccount(accountID: "acct_requested", fingerprint: "requested")
    let other = makeReauthenticationAccount(accountID: "acct_other", fingerprint: "other-old")
    let result = makeReauthenticationResult(accountID: "acct_other", fingerprint: "other-new")

    #expect(
        AccountResolution.reauthenticationTarget(requested: requested, result: result, accounts: [requested, other])
            == .existingAccount(other.id)
    )
}

@MainActor
@Test func reauthenticationCreatesSeparateRecordForUnexpectedNewIdentity() {
    let requested = makeReauthenticationAccount(accountID: "acct_requested", fingerprint: "requested")
    let result = makeReauthenticationResult(accountID: "acct_new", fingerprint: "new")

    #expect(
        AccountResolution.reauthenticationTarget(requested: requested, result: result, accounts: [requested])
            == .newAccount
    )
}

private func makeReauthenticationAccount(accountID: String, fingerprint: String) -> StoredAccount {
    let id = UUID()
    return StoredAccount(
        id: id,
        label: accountID,
        email: "\(accountID)@example.com",
        accountId: accountID,
        planType: "pro",
        createdAt: .distantPast,
        updatedAt: .distantPast,
        lastValidatedAt: nil,
        status: .needsReauth,
        statusMessage: nil,
        lastRateLimit: nil,
        lastRateLimitsByLimitId: nil,
        authFingerprint: fingerprint,
        keychainAccount: "account.\(id.uuidString)"
    )
}

private func makeReauthenticationResult(accountID: String, fingerprint: String) -> AccountValidationResult {
    AccountValidationResult(
        authData: Data(fingerprint.utf8),
        authFingerprint: fingerprint,
        identity: AuthIdentity(
            authMode: "chatgpt",
            accountId: accountID,
            email: "\(accountID)@example.com"
        ),
        email: "\(accountID)@example.com",
        planType: "pro",
        rateLimit: nil,
        rateLimitsByLimitId: nil
    )
}
