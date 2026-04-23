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

