import Foundation
import LimitsShared
import Testing
@testable import LimitsCore

@Test func overviewAndAccountUseTheSameTokenCreditAndCostValues() throws {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let day = CodexUsageRepository.startOfUTCDay(now.addingTimeInterval(-60 * 60))
    let account = insightsAccount(now: now)
    let usage = CodexTokenUsage(inputTokens: 100_000, cachedInputTokens: 20_000, outputTokens: 10_000, reasoningOutputTokens: 8_000, totalTokens: 110_000)
    let server = CodexAccountUsageSnapshot(
        accountID: "acct_insights",
        observedAt: now,
        summary: CodexAccountUsageSummary(
            lifetimeTokens: 500_000,
            peakDailyTokens: 120_000,
            longestRunningTurnSeconds: nil,
            currentStreakDays: nil,
            longestStreakDays: nil
        ),
        dailyActivity: [CodexDailyTokenActivity(date: day, tokens: 120_000)]
    )
    let observations = burnObservations(accountID: "acct_insights", now: now)
    let repository = CodexUsageRepositorySnapshot(
        accountUsage: ["acct_insights": server],
        dailyUsage: [
            CodexStoredDailyUsage(
                date: day,
                accountID: "acct_insights",
                modelID: "gpt-5.6-sol",
                attribution: .confirmed,
                contextTier: .standard,
                usage: usage
            ),
        ],
        limitObservations: ["acct_insights": observations],
        latestLimits: [:],
        rateCardRevisions: []
    )

    let snapshot = CodexUsagePresentation.makeSnapshot(
        accounts: [account],
        repository: repository,
        period: .currentWeek,
        rateCard: OpenAIPricingCatalog.bundledRevision,
        now: now
    )
    let accountSnapshot = try #require(snapshot.accounts.first)

    #expect(snapshot.totals == accountSnapshot.totals)
    #expect(snapshot.models == accountSnapshot.models)
    #expect(snapshot.daily == accountSnapshot.daily)
    #expect(snapshot.totals.usage.totalTokens == 120_000)
    #expect(snapshot.coverage == UsageCoverage(observedTokens: 110_000, serverTokens: 120_000))
    #expect(snapshot.nearestRiskAccountID == "acct_insights")
    #expect(snapshot.totalMonthlySubscriptionUSD == 200)
    let widget = CodexAnalyticsSurfacePresentation.widgetSummary(from: snapshot)
    let tray = CodexAnalyticsSurfacePresentation.trayForecast(
        from: snapshot,
        currentAccountID: "acct_insights",
        now: now
    )
    #expect(widget.weeklyTokens == snapshot.totals.usage.totalTokens)
    #expect(widget.weeklyCredits == snapshot.totals.credits)
    #expect(widget.remainingPercent == accountSnapshot.forecast.remainingPercent)
    #expect(tray == CodexInsightsTextPresentation.forecast(accountSnapshot.forecast, now: now))
}

@Test func unknownModelsKeepTokensVisibleAndMarkMoneyAsUnavailable() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let account = insightsAccount(now: now)
    let day = CodexUsageRepository.startOfUTCDay(now)
    let repository = CodexUsageRepositorySnapshot(
        accountUsage: [:],
        dailyUsage: [
            CodexStoredDailyUsage(
                date: day,
                accountID: "acct_insights",
                modelID: "future-model",
                attribution: .confirmed,
                usage: CodexTokenUsage(inputTokens: 10, outputTokens: 5, totalTokens: 15)
            ),
        ],
        limitObservations: [:],
        latestLimits: [:],
        rateCardRevisions: []
    )

    let snapshot = CodexUsagePresentation.makeSnapshot(
        accounts: [account],
        repository: repository,
        period: .last30Days,
        rateCard: OpenAIPricingCatalog.bundledRevision,
        now: now
    )

    #expect(snapshot.totals.usage.totalTokens == 15)
    #expect(snapshot.totals.credits == nil)
    #expect(snapshot.totals.apiEquivalentUSD == nil)
    #expect(snapshot.models.first?.modelID == "future-model")
}

@Test func accountWithoutObservedTokensDoesNotPretendThatCostIsZero() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let snapshot = CodexUsagePresentation.makeSnapshot(
        accounts: [insightsAccount(now: now)],
        repository: CodexUsageRepositorySnapshot(
            accountUsage: [:],
            dailyUsage: [],
            limitObservations: [:],
            latestLimits: [:],
            rateCardRevisions: []
        ),
        period: .currentWeek,
        rateCard: OpenAIPricingCatalog.bundledRevision,
        now: now
    )

    #expect(snapshot.totals.usage == .zero)
    #expect(snapshot.totals.credits == nil)
    #expect(snapshot.totals.apiEquivalentUSD == nil)
    #expect(snapshot.accounts.first?.totals.credits == nil)
}

@Test func historicalCreditsKeepTheirEventRevisionWhileAPIEquivalentUsesCurrentPricing() {
    let now = Date(timeIntervalSince1970: 3_000_000)
    let oldRevision = insightsRateRevision(id: "old", observedAt: now.addingTimeInterval(-2 * 86_400), creditInput: 100, apiInput: 1)
    let currentRevision = insightsRateRevision(id: "current", observedAt: now.addingTimeInterval(-86_400), creditInput: 200, apiInput: 4)
    let usage = CodexTokenUsage(inputTokens: 1_000_000, totalTokens: 1_000_000)
    let repository = CodexUsageRepositorySnapshot(
        accountUsage: [:],
        dailyUsage: [
            CodexStoredDailyUsage(
                date: now.addingTimeInterval(-36 * 60 * 60),
                accountID: "acct_insights",
                modelID: "gpt-5.6-sol",
                attribution: .confirmed,
                rateRevisionID: oldRevision.id,
                contextTier: .standard,
                usage: usage
            ),
            CodexStoredDailyUsage(
                date: now.addingTimeInterval(-12 * 60 * 60),
                accountID: "acct_insights",
                modelID: "gpt-5.6-sol",
                attribution: .confirmed,
                rateRevisionID: currentRevision.id,
                contextTier: .standard,
                usage: usage
            ),
        ],
        limitObservations: [:],
        latestLimits: [:],
        rateCardRevisions: [oldRevision, currentRevision]
    )

    let snapshot = CodexUsagePresentation.makeSnapshot(
        accounts: [insightsAccount(now: now)],
        repository: repository,
        period: .all,
        rateCard: currentRevision,
        now: now
    )

    #expect(snapshot.totals.credits == 300)
    #expect(snapshot.totals.apiEquivalentUSD == 8)
}

@Test func everyPriceChangeMetricHasReadableTextInEverySupportedLanguage() {
    for language in L10n.supportedLocalizations {
        L10n.withLanguage(language) {
            for metric in OpenAIPriceMetric.allCases {
                let title = CodexInsightsTextPresentation.priceMetricTitle(metric)
                #expect(title != "insights.price_change.metric.\(metric.rawValue)")
                #expect(!title.isEmpty)
            }
        }
    }
}

private func insightsAccount(now: Date) -> StoredAccount {
    StoredAccount(
        id: UUID(),
        label: "Primary",
        email: "primary@example.com",
        accountId: "acct_insights",
        planType: "pro",
        createdAt: now.addingTimeInterval(-30 * 24 * 60 * 60),
        updatedAt: now,
        lastValidatedAt: now,
        status: .ok,
        statusMessage: nil,
        authFingerprint: "fingerprint",
        keychainAccount: "keychain",
        subscriptionPeriod: ChatGPTSubscriptionPeriod(
            activeStart: now.addingTimeInterval(-15 * 24 * 60 * 60),
            activeUntil: now.addingTimeInterval(15 * 24 * 60 * 60),
            lastCheckedAt: now
        )
    )
}

private func burnObservations(accountID: String, now: Date) -> [CodexLimitObservation] {
    let reset = now.addingTimeInterval(2 * 60 * 60)
    return [
        (now.addingTimeInterval(-60 * 60), 50),
        (now.addingTimeInterval(-30 * 60), 65),
        (now, 80),
    ].map { date, used in
        CodexLimitObservation(
            accountID: accountID,
            limitID: "codex",
            window: .secondary,
            observedAt: date,
            usedPercent: used,
            resetsAt: reset,
            windowDurationMinutes: 10_080
        )
    }
}

private func insightsRateRevision(
    id: String,
    observedAt: Date,
    creditInput: Decimal,
    apiInput: Decimal
) -> OpenAIRateCardRevision {
    let rate = OpenAIModelRate(
        modelID: "gpt-5.6-sol",
        creditsPerMillionInput: creditInput,
        creditsPerMillionCachedInput: 0,
        creditsPerMillionOutput: 0,
        usdPerMillionInput: apiInput,
        usdPerMillionCachedInput: 0,
        usdPerMillionCacheWrite: 0,
        usdPerMillionOutput: 0
    )
    return OpenAIRateCardRevision(
        id: id,
        observedAt: observedAt,
        checkedAt: observedAt,
        sourceHashes: ["fixture": id],
        rates: [rate.modelID: rate]
    )
}
