import Foundation
import Testing
@testable import LimitsCore

@Test func accountUsageResponseDecodesOfficialSummaryDailyAndOptionalThreadEvidence() throws {
    let data = Data(
        """
        {
          "summary": {
            "lifetimeTokens": 123456,
            "peakDailyTokens": 45000,
            "longestRunningTurnSec": 321,
            "currentStreakDays": 4,
            "longestStreakDays": 9
          },
          "dailyUsageBuckets": [
            {"startDate":"2026-08-20","tokens":12000},
            {"startDate":"2026-08-21","tokens":15000}
          ],
          "threadUsage": {
            "threadId":"thread-1",
            "estimatedUsageCreditsMicros":1250000,
            "estimatedUsageUsdMicros":25000,
            "groups":[{
              "model":"gpt-5.6-sol",
              "reasoningEffort":"high",
              "speed":"fast",
              "inputTokens":1000,
              "cachedInputTokens":200,
              "netNewInputTokens":800,
              "outputTokens":100,
              "totalTokens":1100,
              "estimatedUsageCreditsMicros":1250000
            }]
          }
        }
        """.utf8
    )
    let response = try JSONDecoder.limits.decode(AppServerAccountUsageResponse.self, from: data)
    let observedAt = try Date("2026-08-21T12:00:00Z", strategy: .iso8601)
    let snapshot = try CodexAccountService.makeUsageSnapshot(response, accountID: "acct", observedAt: observedAt)

    #expect(snapshot.summary.lifetimeTokens == 123_456)
    #expect(snapshot.summary.longestRunningTurnSeconds == 321)
    #expect(snapshot.dailyActivity.map(\.tokens) == [12_000, 15_000])
    #expect(response.threadUsage?.groups.first?.model == "gpt-5.6-sol")
    #expect(response.threadUsage?.groups.first?.estimatedUsageCreditsMicros == 1_250_000)
    let thread = try #require(response.threadUsage)
    let evidence = CodexAccountService.makeThreadUsageEvidence(thread, accountID: "acct", observedAt: observedAt)
    #expect(evidence.threadID == "thread-1")
    #expect(evidence.groups.first?.usage.totalTokens == 1_100)
}

@Test func malformedAccountUsageDayIsRejectedAsOneIndependentEndpointFailure() throws {
    let data = Data(
        """
        {"summary":{},"dailyUsageBuckets":[{"startDate":"not-a-day","tokens":10}]}
        """.utf8
    )
    let response = try JSONDecoder.limits.decode(AppServerAccountUsageResponse.self, from: data)
    #expect(throws: CodexAccountServiceError.self) {
        _ = try CodexAccountService.makeUsageSnapshot(response, accountID: "acct", observedAt: .now)
    }
}
