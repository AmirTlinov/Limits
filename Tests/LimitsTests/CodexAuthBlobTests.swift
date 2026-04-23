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

    #expect(snapshot.compactUsageSummary() == "5ч 9% · Неделя 60%")
    #expect(snapshot.compactResetSummary(now: now) == "6д 17ч")
    #expect(snapshot.panelSummary(now: now) == "5ч 9% · Неделя 60% | 6д 17ч")
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

@MainActor
@Test func storedAccountMatchRequiresSameFingerprintWhenAccountIdMatches() {
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
        identity: AuthIdentity(authMode: "chatgpt", accountId: "acct_123"),
        fingerprint: "different-fingerprint",
        accounts: [stored]
    )

    #expect(match == nil)
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
        identity: AuthIdentity(authMode: "chatgpt", accountId: "acct_123"),
        fingerprint: "same-fingerprint",
        accounts: [stored]
    )

    #expect(match?.id == id)
}
