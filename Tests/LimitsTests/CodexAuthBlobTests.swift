import Foundation
import Testing
@testable import LimitsCore
import LimitsShared

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

@Test func readsChatGPTPlanAndPaidPeriodFromRefreshedIDToken() throws {
    let header = base64URLJSON(["alg": "none"])
    let payload = base64URLJSON([
        "email": "user@example.com",
        "https://api.openai.com/auth": [
            "chatgpt_plan_type": "pro",
            "chatgpt_subscription_active_start": "2026-08-07T22:34:20+00:00",
            "chatgpt_subscription_active_until": "2026-09-07T22:34:20+00:00",
            "chatgpt_subscription_last_checked": "2026-08-19T21:47:30.959820+00:00",
        ],
    ])
    let data = """
    {
      "auth_mode": "chatgpt",
      "tokens": {
        "account_id": "acct_123",
        "id_token": "\(header).\(payload).signature"
      }
    }
    """.data(using: .utf8)!

    let metadata = try CodexAuthBlob.metadata(from: data)
    let expectedStart = try #require(ISO8601DateFormatter().date(from: "2026-08-07T22:34:20+00:00"))
    let expectedUntil = try #require(ISO8601DateFormatter().date(from: "2026-09-07T22:34:20+00:00"))

    #expect(metadata.identity.email == "user@example.com")
    #expect(metadata.planType == "pro")
    #expect(metadata.subscriptionPeriod?.activeStart == expectedStart)
    #expect(metadata.subscriptionPeriod?.activeUntil == expectedUntil)
    #expect(metadata.subscriptionPeriod?.lastCheckedAt != nil)
}

@Test func chatGPTPlanPresentationDistinguishesPlusAndBothProTiers() {
    L10n.withLanguage("en") {
        #expect(ChatGPTSubscriptionPresentationPolicy.plan(for: "plus").summary == "ChatGPT Plus · $20/month")
        #expect(ChatGPTSubscriptionPresentationPolicy.plan(for: "prolite").summary == "ChatGPT Pro 5× · $100/month")
        #expect(ChatGPTSubscriptionPresentationPolicy.plan(for: "pro").summary == "ChatGPT Pro 20× · $200/month")
    }
}

@Test func subscriptionPresentationNamesPaidPeriodWithoutClaimingCancellation() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let current = ChatGPTSubscriptionPeriod(
        activeStart: now.addingTimeInterval(-1_000),
        activeUntil: now.addingTimeInterval(1_000),
        lastCheckedAt: now
    )
    let past = ChatGPTSubscriptionPeriod(
        activeStart: now.addingTimeInterval(-2_000),
        activeUntil: now.addingTimeInterval(-1_000),
        lastCheckedAt: now.addingTimeInterval(-1_500)
    )

    L10n.withLanguage("ru") {
        #expect(ChatGPTSubscriptionPresentationPolicy.periodText(for: current, now: now)?.hasPrefix("Текущий оплаченный период до ") == true)
        #expect(ChatGPTSubscriptionPresentationPolicy.periodText(for: past, now: now)?.hasPrefix("Последний подтверждённый период закончился ") == true)
    }
}

private func base64URLJSON(_ object: [String: Any]) -> String {
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

@Test func codexAccountValidationSucceedsWhenOnlyLimitsAreUnavailable() throws {
    let resolved = try CodexAccountService.resolveValidatedIdentity(
        account: AppServerAccountPayload(type: "chatgpt", email: "user@example.com", planType: "pro"),
        identity: AuthIdentity(authMode: "chatgpt", accountId: "acct_123", email: "user@example.com"),
        rateLimitsResponse: nil
    )
    #expect(resolved.email == "user@example.com")
    #expect(resolved.planType == "pro")
}

@Test func codexAccountValidationUsesRefreshedTokenPlanWhenAccountSurfaceOmitsIt() throws {
    let resolved = try CodexAccountService.resolveValidatedIdentity(
        account: nil,
        identity: AuthIdentity(authMode: "chatgpt", accountId: "acct_123", email: "user@example.com"),
        authPlanType: "prolite",
        rateLimitsResponse: nil
    )

    #expect(resolved.planType == "prolite")
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

    let match = AccountResolution.storedCodexMatch(
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

    let ambiguous = AccountResolution.storedCodexMatch(
        identity: AuthIdentity(authMode: "chatgpt", accountId: "acct_123", email: nil),
        fingerprint: "rotated",
        accounts: accounts
    )
    let exact = AccountResolution.storedCodexMatch(
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

    let match = AccountResolution.storedCodexMatch(
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

    let match = AccountResolution.importedCodexAccount(
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

    let match = AccountResolution.importedCodexAccount(
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
      "schemaVersion": 3,
      "revision": 7,
      "accounts": [
        {
          "id": "E621E6F8-C36C-495A-93FC-2C07A5F7D319",
          "label": "Legacy v3 account",
          "email": "legacy@example.com",
          "accountId": "acct_legacy",
          "planType": "plus",
          "createdAt": "2026-08-01T00:00:00Z",
          "updatedAt": "2026-08-20T00:00:00Z",
          "lastValidatedAt": "2026-08-20T00:00:00Z",
          "status": "ok",
          "authFingerprint": "legacy-fingerprint",
          "keychainAccount": "legacy-keychain-reference"
        }
      ]
    }
    """.data(using: .utf8)!

    let state = try JSONDecoder.limits.decode(PersistedStateV3.self, from: data)

    let account = try #require(state.accounts.first)
    #expect(account.lastRateLimitObservedAt == nil)
    #expect(account.subscriptionPeriod == nil)
    #expect(account.rateLimitObservedAt == account.lastValidatedAt)
    #expect(state.claudeAccounts.isEmpty)
}

@Test func validationMergePreservesLastKnownLimitsWhenOnlyRateLimitEndpointFails() throws {
    let oldObservedAt = Date(timeIntervalSince1970: 1_000_000)
    let now = oldObservedAt.addingTimeInterval(600)
    let oldSnapshot = RateLimitSnapshotModel(
        credits: nil,
        limitId: "codex",
        limitName: nil,
        planType: "pro",
        primary: RateLimitWindowSnapshot(
            resetsAt: Int64(now.addingTimeInterval(3_600).timeIntervalSince1970),
            usedPercent: 80,
            windowDurationMins: 300
        ),
        rateLimitReachedType: "rate_limit_exceeded",
        secondary: nil
    )
    let paidPeriod = ChatGPTSubscriptionPeriod(
        activeStart: oldObservedAt,
        activeUntil: now.addingTimeInterval(86_400),
        lastCheckedAt: oldObservedAt
    )
    let account = StoredAccount(
        id: UUID(),
        label: "Primary",
        email: "old@example.com",
        accountId: "acct_123",
        planType: "pro",
        createdAt: oldObservedAt,
        updatedAt: oldObservedAt,
        lastValidatedAt: oldObservedAt,
        status: .limitReached,
        statusMessage: "Rate Limit Exceeded",
        lastRateLimit: oldSnapshot,
        lastRateLimitsByLimitId: ["codex": oldSnapshot],
        authFingerprint: "old-fingerprint",
        keychainAccount: "account-key",
        lastRateLimitObservedAt: oldObservedAt,
        subscriptionPeriod: paidPeriod
    )
    let result = AccountValidationResult(
        authData: Data("rotated".utf8),
        authFingerprint: "new-fingerprint",
        identity: AuthIdentity(authMode: "chatgpt", accountId: "acct_123", email: "new@example.com"),
        email: "new@example.com",
        planType: "pro",
        rateLimit: nil,
        rateLimitsByLimitId: nil,
        rateLimitError: "Limits are temporarily unavailable"
    )

    let updated = CodexAccountValidationPolicy.applying(result, to: account, observedAt: now)

    #expect(updated.lastValidatedAt == now)
    #expect(updated.lastRateLimitObservedAt == oldObservedAt)
    #expect(updated.lastRateLimit == oldSnapshot)
    #expect(updated.lastRateLimitsByLimitId == ["codex": oldSnapshot])
    #expect(updated.subscriptionPeriod == paidPeriod)
    #expect(updated.status == .ok)
    #expect(updated.statusMessage == "Limits are temporarily unavailable")
    #expect(updated.authFingerprint == "new-fingerprint")
}

@Test func validationMergeUsesEveryExactBucketWhenDeterminingAvailability() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let spendControl = RateLimitSnapshotModel(
        credits: nil,
        limitId: "spend_control",
        limitName: nil,
        planType: "business",
        primary: nil,
        rateLimitReachedType: nil,
        secondary: nil,
        spendControlReached: true
    )
    let result = AccountValidationResult(
        authData: Data("credential".utf8),
        authFingerprint: "fingerprint",
        identity: AuthIdentity(authMode: "chatgpt", accountId: "acct_123", email: "user@example.com"),
        email: "user@example.com",
        planType: "business",
        rateLimit: nil,
        rateLimitsByLimitId: ["spend_control": spendControl]
    )

    let account = CodexAccountValidationPolicy.makeAccount(
        id: UUID(),
        label: "Business",
        createdAt: now,
        from: result,
        observedAt: now
    )

    #expect(account.status == .limitReached)
    #expect(account.lastRateLimitObservedAt == now)
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
