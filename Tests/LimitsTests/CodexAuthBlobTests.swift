import Foundation
import Testing
@testable import Limits

@Test func readsChatGPTIdentityFromAuthBlob() throws {
    let data = """
    {
      "auth_mode": "chatgpt",
      "tokens": {
        "account_id": "acct_123"
      }
    }
    """.data(using: .utf8)!

    let identity = try CodexAuthBlob.identity(from: data)

    #expect(identity.authMode == "chatgpt")
    #expect(identity.accountId == "acct_123")
}

@Test func readsEmailFromChatGPTIDTokenWhenAccountSurfaceOmitsAccountPayload() throws {
    let header = base64URLJSON(["alg": "none"])
    let payload = base64URLJSON(["email": "user@example.com"])
    let data = """
    {
      "auth_mode": "chatgpt",
      "tokens": {
        "account_id": "acct_123",
        "id_token": "\(header).\(payload).signature"
      }
    }
    """.data(using: .utf8)!

    let identity = try CodexAuthBlob.identity(from: data)

    #expect(identity.email == "user@example.com")
}

private func base64URLJSON(_ object: [String: String]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

@Test func rateLimitReachedWhenPrimaryWindowHitsHundredPercent() {
    let snapshot = RateLimitSnapshotModel(
        credits: nil,
        limitId: "codex",
        limitName: nil,
        planType: "pro",
        primary: RateLimitWindowSnapshot(resetsAt: nil, usedPercent: 100, windowDurationMins: 300),
        rateLimitReachedType: nil,
        secondary: nil
    )

    #expect(snapshot.isReached)
}

@Test func panelSummaryFormatsPrimarySecondaryAndResetCompactly() {
    let snapshot = RateLimitSnapshotModel(
        credits: nil,
        limitId: "codex",
        limitName: nil,
        planType: "pro",
        primary: RateLimitWindowSnapshot(resetsAt: 1_777_000_000, usedPercent: 9, windowDurationMins: 300),
        rateLimitReachedType: nil,
        secondary: RateLimitWindowSnapshot(resetsAt: 1_777_579_600, usedPercent: 60, windowDurationMins: 10_080)
    )

    let now = Date(timeIntervalSince1970: 1_777_000_000 - 600)

    L10n.withLanguage("ru") {
        #expect(snapshot.compactUsageSummary() == "5ч 9% · Неделя 60%")
        #expect(snapshot.compactResetSummary(now: now) == "6д 17ч")
        #expect(snapshot.panelSummary(now: now) == "5ч 9% · Неделя 60% | 6д 17ч")
    }
}

@Test func displayBuilderKeepsCodexFirstAndModelSectionsAfterIt() {
    let codex = RateLimitSnapshotModel(
        credits: nil,
        limitId: "codex",
        limitName: nil,
        planType: "pro",
        primary: RateLimitWindowSnapshot(resetsAt: 1_777_000_000, usedPercent: 9, windowDurationMins: 300),
        rateLimitReachedType: nil,
        secondary: RateLimitWindowSnapshot(resetsAt: 1_777_579_600, usedPercent: 60, windowDurationMins: 10_080)
    )

    let spark = RateLimitSnapshotModel(
        credits: nil,
        limitId: "codex_bengalfox",
        limitName: "GPT-5.3-Codex-Spark",
        planType: "pro",
        primary: RateLimitWindowSnapshot(resetsAt: 1_777_000_000, usedPercent: 15, windowDurationMins: 300),
        rateLimitReachedType: nil,
        secondary: RateLimitWindowSnapshot(resetsAt: 1_777_579_600, usedPercent: 5, windowDurationMins: 10_080)
    )

    let sections = RateLimitDisplayBuilder.makeSections(
        primary: codex,
        byLimitId: ["codex": codex, "codex_bengalfox": spark]
    )

    #expect(sections.count == 2)
    #expect(sections.first?.title == "Codex CLI")
    #expect(sections.last?.title == "GPT-5.3-Codex-Spark")
}

@Test func codexValidationAcceptsRateLimitsWhenAccountReadReturnsNoPayload() throws {
    let snapshot = RateLimitSnapshotModel(
        credits: nil,
        limitId: "codex",
        limitName: nil,
        planType: "pro",
        primary: RateLimitWindowSnapshot(resetsAt: nil, usedPercent: 0, windowDurationMins: 300),
        rateLimitReachedType: nil,
        secondary: nil
    )

    let resolved = try CodexAccountService.resolveValidatedIdentity(
        account: nil,
        identity: AuthIdentity(authMode: "chatgpt", accountId: "acct_123", email: "user@example.com"),
        rateLimitsResponse: AppServerRateLimitsResponse(rateLimits: snapshot, rateLimitsByLimitId: ["codex": snapshot])
    )

    #expect(resolved.email == "user@example.com")
    #expect(resolved.planType == "pro")
}

@Test func codexValidationRejectsAccountOnlySuccessWithoutLiveRateLimits() {
    do {
        _ = try CodexAccountService.resolveValidatedIdentity(
            account: AppServerAccountPayload(type: "chatgpt", email: "user@example.com", planType: "pro"),
            identity: AuthIdentity(authMode: "chatgpt", accountId: "acct_123", email: "user@example.com"),
            rateLimitsResponse: nil
        )
        #expect(Bool(false), "Validation should fail when live rate limits are unavailable.")
    } catch CodexAccountServiceError.missingRateLimits {
        #expect(Bool(true))
    } catch {
        #expect(Bool(false), "Unexpected error: \(error)")
    }
}

@MainActor
@Test func storedAccountMatchUsesStableAccountIdWhenCredentialRotates() {
    let id = UUID()
    let stored = StoredAccount(
        id: id,
        label: "Primary",
        email: "user@example.com",
        accountId: "acct_123",
        planType: "pro",
        createdAt: .distantPast,
        updatedAt: .distantPast,
        lastValidatedAt: nil,
        status: .ok,
        statusMessage: nil,
        lastRateLimit: nil,
        lastRateLimitsByLimitId: nil,
        authFingerprint: "stored-fingerprint",
        keychainAccount: "account.\(id.uuidString)"
    )

    let match = AppModel.resolveStoredAccountMatch(
        identity: AuthIdentity(authMode: "chatgpt", accountId: "acct_123", email: nil),
        fingerprint: "different-fingerprint",
        accounts: [stored]
    )

    #expect(match?.id == id)
}

@MainActor
@Test func storedAccountMatchRefusesAmbiguousStableIdentityWithoutExactCredential() {
    let firstID = UUID()
    let secondID = UUID()
    let baseDate = Date(timeIntervalSince1970: 100)
    let accounts = [
        StoredAccount(
            id: firstID,
            label: "First",
            email: "user@example.com",
            accountId: "acct_123",
            planType: "pro",
            createdAt: baseDate,
            updatedAt: baseDate,
            lastValidatedAt: baseDate,
            status: .ok,
            statusMessage: nil,
            lastRateLimit: nil,
            lastRateLimitsByLimitId: nil,
            authFingerprint: "first",
            keychainAccount: "account.\(firstID.uuidString)"
        ),
        StoredAccount(
            id: secondID,
            label: "Second",
            email: "user@example.com",
            accountId: "acct_123",
            planType: "pro",
            createdAt: baseDate,
            updatedAt: baseDate,
            lastValidatedAt: baseDate,
            status: .ok,
            statusMessage: nil,
            lastRateLimit: nil,
            lastRateLimitsByLimitId: nil,
            authFingerprint: "second",
            keychainAccount: "account.\(secondID.uuidString)"
        ),
    ]

    let ambiguous = AppModel.resolveStoredAccountMatch(
        identity: AuthIdentity(authMode: "chatgpt", accountId: "acct_123", email: nil),
        fingerprint: "rotated",
        accounts: accounts
    )
    let exact = AppModel.resolveStoredAccountMatch(
        identity: AuthIdentity(authMode: "chatgpt", accountId: "acct_123", email: nil),
        fingerprint: "second",
        accounts: accounts
    )

    #expect(ambiguous == nil)
    #expect(exact?.id == secondID)
}

@MainActor
@Test func storedAccountMatchAcceptsSameAccountIdAndFingerprint() {
    let id = UUID()
    let stored = StoredAccount(
        id: id,
        label: "Primary",
        email: "user@example.com",
        accountId: "acct_123",
        planType: "pro",
        createdAt: .distantPast,
        updatedAt: .distantPast,
        lastValidatedAt: nil,
        status: .ok,
        statusMessage: nil,
        lastRateLimit: nil,
        lastRateLimitsByLimitId: nil,
        authFingerprint: "same-fingerprint",
        keychainAccount: "account.\(id.uuidString)"
    )

    let match = AppModel.resolveStoredAccountMatch(
        identity: AuthIdentity(authMode: "chatgpt", accountId: "acct_123", email: nil),
        fingerprint: "same-fingerprint",
        accounts: [stored]
    )

    #expect(match?.id == id)
}

@MainActor
@Test func importedAccountResolutionAcceptsKnownAccountIdEvenWhenFingerprintChanged() {
    let id = UUID()
    let stored = StoredAccount(
        id: id,
        label: "Primary",
        email: "user@example.com",
        accountId: "acct_123",
        planType: "pro",
        createdAt: .distantPast,
        updatedAt: .distantPast,
        lastValidatedAt: nil,
        status: .ok,
        statusMessage: nil,
        lastRateLimit: nil,
        lastRateLimitsByLimitId: nil,
        authFingerprint: "old-fingerprint",
        keychainAccount: "account.\(id.uuidString)"
    )

    let match = AppModel.resolveImportedAccount(
        fingerprint: "new-fingerprint",
        accountId: "acct_123",
        email: nil,
        accounts: [stored]
    )

    #expect(match?.id == id)
}

@MainActor
@Test func importedAccountResolutionAcceptsKnownEmailWhenAccountIdIsMissing() {
    let id = UUID()
    let stored = StoredAccount(
        id: id,
        label: "Primary",
        email: "user@example.com",
        accountId: nil,
        planType: "pro",
        createdAt: .distantPast,
        updatedAt: .distantPast,
        lastValidatedAt: nil,
        status: .ok,
        statusMessage: nil,
        lastRateLimit: nil,
        lastRateLimitsByLimitId: nil,
        authFingerprint: "old-fingerprint",
        keychainAccount: "account.\(id.uuidString)"
    )

    let match = AppModel.resolveImportedAccount(
        fingerprint: "new-fingerprint",
        accountId: nil,
        email: "USER@example.com",
        accounts: [stored]
    )

    #expect(match?.id == id)
}

@Test func persistedStateDecodesWithoutClaudeAccountsField() throws {
    let data = """
    {
      "accounts": []
    }
    """.data(using: .utf8)!

    let state = try JSONDecoder.limits.decode(PersistedState.self, from: data)

    #expect(state.accounts.isEmpty)
    #expect(state.claudeAccounts.isEmpty)
}

@Test func decodesClaudeAuthStatusJson() throws {
    let data = """
    {
      "loggedIn": true,
      "authMethod": "claude.ai",
      "apiProvider": "firstParty",
      "email": "user@example.com",
      "orgId": "org_123",
      "orgName": "Example Org",
      "subscriptionType": "max"
    }
    """.data(using: .utf8)!

    let status = try JSONDecoder.limits.decode(ClaudeAuthStatus.self, from: data)

    #expect(status.loggedIn)
    #expect(status.email == "user@example.com")
    #expect(status.subscriptionType == "max")
}
