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

    let snapshot = CodexUsagePresentation.makeSnapshotSet(
        accounts: [account],
        repository: repository,
        rateCard: OpenAIPricingCatalog.bundledRevision,
        now: now
    ).currentWeek
    let accountSnapshot = try #require(snapshot.accounts.first)

    #expect(snapshot.totals == accountSnapshot.totals)
    #expect(snapshot.models == accountSnapshot.models)
    #expect(snapshot.daily == accountSnapshot.daily)
    #expect(snapshot.totals.usage.totalTokens == 120_000)
    #expect(snapshot.daily.first?.totals.usage.totalTokens == 120_000)
    #expect(snapshot.coverage == UsageCoverage(observedTokens: 110_000, serverTokens: 120_000))
    #expect(snapshot.nearestRisk?.accountID == "acct_insights")
    #expect(snapshot.totalMonthlySubscriptionUSD == 200)
    let widget = CodexAnalyticsSurfacePresentation.widgetSummary(from: snapshot)
    let tray = CodexAnalyticsSurfacePresentation.trayForecast(
        from: snapshot,
        currentAccountID: "acct_insights",
        now: now
    )
    #expect(widget.weeklyTokens == snapshot.totals.usage.totalTokens)
    #expect(widget.weeklyCredits == snapshot.totals.credits)
    #expect(widget.remainingPercent == accountSnapshot.riskiestQuotaForecast?.forecast.remainingPercent)
    #expect(tray == "Codex · \(CodexInsightsTextPresentation.forecast(try #require(accountSnapshot.riskiestQuotaForecast).forecast, now: now))")
}

@Test func workBreakdownUsesOnlySavedAccountRowsAndKeepsRealProjectAndTaskNames() throws {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let day = CodexUsageRepository.startOfUTCDay(now.addingTimeInterval(-60 * 60))
    let account = insightsAccount(now: now)
    let repository = CodexUsageRepositorySnapshot(
        accountUsage: [:],
        dailyUsage: [storedDaily(accountID: "acct_insights", day: day, model: "gpt-5.6-sol", tokens: 100)],
        workUsage: [
            CodexStoredWorkUsage(
                date: day,
                accountID: "acct_insights",
                threadID: "thread-limits",
                projectID: "repo:limits",
                projectTitle: "Limits",
                taskTitle: "Repair analytics",
                usage: CodexTokenUsage(inputTokens: 80, outputTokens: 20, totalTokens: 100)
            ),
            CodexStoredWorkUsage(
                date: day,
                accountID: nil,
                threadID: "thread-unattributed",
                projectID: "repo:other",
                projectTitle: "Other",
                taskTitle: "Unattributed work",
                usage: CodexTokenUsage(inputTokens: 900, totalTokens: 900)
            ),
        ],
        limitObservations: ["acct_insights": burnObservations(accountID: "acct_insights", now: now)],
        latestLimits: [:],
        rateCardRevisions: []
    )

    let snapshot = CodexUsagePresentation.makeSnapshotSet(
        accounts: [account],
        repository: repository,
        rateCard: OpenAIPricingCatalog.bundledRevision,
        now: now
    ).currentWeek

    let work = try #require(snapshot.work)
    #expect(work.observedTokens == 100)
    #expect(work.window.end == now.addingTimeInterval(1))
    #expect(work.projects == [CodexWorkUsageItem(id: "repo:limits", title: "Limits", subtitle: nil, tokens: 100)])
    #expect(work.tasks == [CodexWorkUsageItem(id: "thread-limits", title: "Repair analytics", subtitle: "Limits", tokens: 100)])
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

    let snapshot = CodexUsagePresentation.makeSnapshotSet(
        accounts: [account],
        repository: repository,
        rateCard: OpenAIPricingCatalog.bundledRevision,
        now: now
    ).last30Days

    #expect(snapshot.totals.usage.totalTokens == 15)
    #expect(snapshot.totals.credits == nil)
    #expect(snapshot.totals.apiEquivalentUSD == nil)
    #expect(snapshot.models.first?.modelID == "future-model")
}

@Test func accountWithoutObservedTokensDoesNotPretendThatCostIsZero() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let snapshot = CodexUsagePresentation.makeSnapshotSet(
        accounts: [insightsAccount(now: now)],
        repository: CodexUsageRepositorySnapshot(
            accountUsage: [:],
            dailyUsage: [],
            limitObservations: [:],
            latestLimits: [:],
            rateCardRevisions: []
        ),
        rateCard: OpenAIPricingCatalog.bundledRevision,
        now: now
    ).currentWeek

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

    let snapshot = CodexUsagePresentation.makeSnapshotSet(
        accounts: [insightsAccount(now: now)],
        repository: repository,
        rateCard: currentRevision,
        now: now
    ).all

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

@Test func quotaForecastsAreIndependentAndDictionaryOrderCannotChangeRisk() throws {
    let now = Date(timeIntervalSince1970: 4_000_000)
    let reset = now.addingTimeInterval(8 * 60 * 60)
    let base = [(0, 10), (30, 11), (60, 12)].map { minutes, used in
        CodexLimitObservation(
            accountID: "acct_insights",
            limitID: "codex",
            window: .secondary,
            observedAt: now.addingTimeInterval(TimeInterval((minutes - 60) * 60)),
            usedPercent: used,
            resetsAt: reset,
            windowDurationMinutes: 10_080
        )
    }
    let spark = [(0, 40), (30, 60), (60, 80)].map { minutes, used in
        CodexLimitObservation(
            accountID: "acct_insights",
            limitID: "codex_bengalfox",
            window: .secondary,
            observedAt: now.addingTimeInterval(TimeInterval((minutes - 60) * 60)),
            usedPercent: used,
            resetsAt: reset,
            windowDurationMinutes: 10_080
        )
    }
    let codex = quotaRateLimit(id: "codex", name: nil, used: 12, reset: reset)
    let sparkLimit = quotaRateLimit(id: "codex_bengalfox", name: "GPT-5.3-Codex-Spark", used: 80, reset: reset)
    let forward = CodexRateLimitsSnapshot(
        accountID: "acct_insights",
        observedAt: now,
        primary: codex,
        byLimitID: ["codex": codex, "codex_bengalfox": sparkLimit],
        errorMessage: nil
    )
    let reverse = CodexRateLimitsSnapshot(
        accountID: "acct_insights",
        observedAt: now,
        primary: codex,
        byLimitID: ["codex_bengalfox": sparkLimit, "codex": codex],
        errorMessage: nil
    )

    let first = CodexQuotaAnalytics.forecasts(
        observations: base + spark,
        latestLimits: forward,
        now: now
    )
    let second = CodexQuotaAnalytics.forecasts(
        observations: Array((base + spark).reversed()),
        latestLimits: reverse,
        now: now
    )

    #expect(first == second)
    #expect(first.count == 2)
    #expect(first.first(where: { $0.key.limitID == "codex" })?.forecast.state == .lastsUntilReset)
    let risky = try #require(first.first(where: { $0.key.limitID == "codex_bengalfox" }))
    #expect(risky.title == "GPT-5.3-Codex-Spark")
    #expect(risky.forecast.state == .exhaustsBeforeReset)
}

@Test func currentWeekUsesEachAccountsOwnBaseQuotaWindow() throws {
    let calendar = CodexUsageWindow.utcCalendar
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 21, hour: 12)))
    let accountA = insightsAccount(id: "account-a", label: "A", now: now)
    let accountB = insightsAccount(id: "account-b", label: "B", now: now)
    let day16 = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 16)))
    let day18 = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 18)))
    let resetA = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 22)))
    let resetB = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 24)))
    let observations: [String: [CodexLimitObservation]] = [
        "account-a": [weeklyBaseObservation(accountID: "account-a", at: now, reset: resetA)],
        "account-b": [weeklyBaseObservation(accountID: "account-b", at: now, reset: resetB)],
    ]
    let serverA = accountUsageSnapshot(accountID: "account-a", now: now, daily: [(day16, 1_000), (day18, 2_000)])
    let serverB = accountUsageSnapshot(accountID: "account-b", now: now, daily: [(day16, 3_000), (day18, 4_000)])
    let snapshot = CodexUsagePresentation.makeSnapshotSet(
        accounts: [accountA, accountB],
        repository: CodexUsageRepositorySnapshot(
            accountUsage: ["account-a": serverA, "account-b": serverB],
            dailyUsage: [],
            limitObservations: observations,
            latestLimits: [:],
            rateCardRevisions: []
        ),
        rateCard: OpenAIPricingCatalog.bundledRevision,
        now: now
    ).currentWeek

    #expect(snapshot.accounts.first(where: { $0.id == "account-a" })?.totals.usage.totalTokens == 3_000)
    #expect(snapshot.accounts.first(where: { $0.id == "account-b" })?.totals.usage.totalTokens == 4_000)
    #expect(snapshot.totals.usage.totalTokens == 7_000)
}

@Test func unattributedHistoryStaysVisibleWithoutChangingSavedAccountHeadline() throws {
    let now = Date(timeIntervalSince1970: 5_000_000)
    let day = CodexUsageRepository.startOfUTCDay(now)
    let account = insightsAccount(now: now)
    let snapshot = CodexUsagePresentation.makeSnapshotSet(
        accounts: [account],
        repository: CodexUsageRepositorySnapshot(
            accountUsage: [:],
            dailyUsage: [
                storedDaily(accountID: "acct_insights", day: day, model: "gpt-5.6-sol", tokens: 100),
                storedDaily(accountID: nil, day: day, model: "gpt-5.6-terra", tokens: 900),
            ],
            limitObservations: [:],
            latestLimits: [:],
            rateCardRevisions: []
        ),
        rateCard: OpenAIPricingCatalog.bundledRevision,
        now: now
    ).all

    #expect(snapshot.totals.usage.totalTokens == 100)
    #expect(snapshot.models.map(\.modelID) == ["gpt-5.6-sol"])
    #expect(snapshot.unattributed?.totals.usage.totalTokens == 900)
    #expect(snapshot.unattributed?.models.map(\.modelID) == ["gpt-5.6-terra"])
}

@Test func aggregateTotalsAreExactlyTheSumOfSavedAccounts() {
    let now = Date(timeIntervalSince1970: 6_000_000)
    let day = CodexUsageRepository.startOfUTCDay(now)
    let accounts = [
        insightsAccount(id: "account-a", label: "A", now: now),
        insightsAccount(id: "account-b", label: "B", now: now),
    ]
    let snapshot = CodexUsagePresentation.makeSnapshotSet(
        accounts: accounts,
        repository: CodexUsageRepositorySnapshot(
            accountUsage: [:],
            dailyUsage: [
                storedDaily(accountID: "account-a", day: day, model: "gpt-5.6-sol", tokens: 123),
                storedDaily(accountID: "account-b", day: day, model: "gpt-5.6-sol", tokens: 456),
                storedDaily(accountID: "removed-account", day: day, model: "gpt-5.6-sol", tokens: 10_000),
            ],
            limitObservations: [:],
            latestLimits: [:],
            rateCardRevisions: []
        ),
        rateCard: OpenAIPricingCatalog.bundledRevision,
        now: now
    ).all

    let sum = snapshot.accounts.reduce(CodexTokenUsage.zero) { $0 + $1.totals.usage }
    #expect(snapshot.totals.usage == sum)
    #expect(snapshot.totals.usage.totalTokens == 579)
    #expect(snapshot.unattributed?.totals.usage.totalTokens == 10_000)
}

@Test func coveragePreservesOverOneHundredPercentAsInconsistentEvidence() throws {
    let now = Date(timeIntervalSince1970: 7_000_000)
    let day = CodexUsageRepository.startOfUTCDay(now)
    let server = accountUsageSnapshot(accountID: "acct_insights", now: now, daily: [(day, 100)])
    let snapshot = CodexUsagePresentation.makeSnapshotSet(
        accounts: [insightsAccount(now: now)],
        repository: CodexUsageRepositorySnapshot(
            accountUsage: ["acct_insights": server],
            dailyUsage: [storedDaily(accountID: "acct_insights", day: day, model: "gpt-5.6-sol", tokens: 120)],
            limitObservations: [:],
            latestLimits: [:],
            rateCardRevisions: []
        ),
        rateCard: OpenAIPricingCatalog.bundledRevision,
        now: now
    ).all
    let coverage = try #require(snapshot.coverage)

    #expect(coverage.observedTokens == 120)
    #expect(coverage.serverTokens == 100)
    #expect(coverage.fraction == 1.2)
    #expect(coverage.hasInconsistentTotals)
}

private func insightsAccount(id: String, label: String, now: Date) -> StoredAccount {
    var account = insightsAccount(now: now)
    account.accountId = id
    account.label = label
    return account
}

private func weeklyBaseObservation(accountID: String, at date: Date, reset: Date) -> CodexLimitObservation {
    CodexLimitObservation(
        accountID: accountID,
        limitID: "codex",
        window: .secondary,
        observedAt: date,
        usedPercent: 20,
        resetsAt: reset,
        windowDurationMinutes: 10_080
    )
}

private func accountUsageSnapshot(
    accountID: String,
    now: Date,
    daily: [(Date, Int64)]
) -> CodexAccountUsageSnapshot {
    CodexAccountUsageSnapshot(
        accountID: accountID,
        observedAt: now,
        summary: CodexAccountUsageSummary(
            lifetimeTokens: daily.reduce(0) { $0 + $1.1 },
            peakDailyTokens: daily.map(\.1).max(),
            longestRunningTurnSeconds: nil,
            currentStreakDays: nil,
            longestStreakDays: nil
        ),
        dailyActivity: daily.map { CodexDailyTokenActivity(date: $0.0, tokens: $0.1) }
    )
}

private func storedDaily(
    accountID: String?,
    day: Date,
    model: String,
    tokens: Int64
) -> CodexStoredDailyUsage {
    CodexStoredDailyUsage(
        date: day,
        accountID: accountID,
        modelID: model,
        attribution: accountID == nil ? .unattributed : .confirmed,
        usage: CodexTokenUsage(inputTokens: tokens, totalTokens: tokens)
    )
}

private func quotaRateLimit(id: String, name: String?, used: Int, reset: Date) -> RateLimitSnapshotModel {
    RateLimitSnapshotModel(
        credits: nil,
        limitId: id,
        limitName: name,
        planType: "pro",
        primary: nil,
        rateLimitReachedType: nil,
        secondary: RateLimitWindowSnapshot(
            resetsAt: Int64(reset.timeIntervalSince1970),
            usedPercent: used,
            windowDurationMins: 10_080
        )
    )
}
