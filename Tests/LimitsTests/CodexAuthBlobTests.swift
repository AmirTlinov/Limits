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
