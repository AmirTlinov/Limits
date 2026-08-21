import Foundation

/// Builds the complete immutable analytics view used by every presentation surface.
public enum CodexUsagePresentation {
    public static func makeSnapshotSet(
        accounts: [StoredAccount],
        repository: CodexUsageRepositorySnapshot,
        rateCard: OpenAIRateCardRevision,
        priceChange: OpenAIPriceChange? = nil,
        now: Date = .now
    ) -> CodexAnalyticsSnapshotSet {
        CodexAnalyticsSnapshotSet(
            currentWeek: makeSnapshot(
                accounts: accounts,
                repository: repository,
                period: .currentWeek,
                rateCard: rateCard,
                priceChange: priceChange,
                now: now
            ),
            last30Days: makeSnapshot(
                accounts: accounts,
                repository: repository,
                period: .last30Days,
                rateCard: rateCard,
                priceChange: priceChange,
                now: now
            ),
            all: makeSnapshot(
                accounts: accounts,
                repository: repository,
                period: .all,
                rateCard: rateCard,
                priceChange: priceChange,
                now: now
            )
        )
    }

    private static func makeSnapshot(
        accounts: [StoredAccount],
        repository: CodexUsageRepositorySnapshot,
        period: CodexUsagePeriod,
        rateCard: OpenAIRateCardRevision,
        priceChange: OpenAIPriceChange?,
        now: Date
    ) -> CodexInsightsSnapshot {
        var accountInsights: [CodexAccountInsights] = []
        var billingPeriodTokens: Int64 = 0
        var knownSubscriptionTotal = Decimal.zero
        var hasKnownSubscription = false

        for account in accounts {
            let accountID = account.accountId
            let observations = accountID.flatMap { repository.limitObservations[$0] } ?? []
            let window = usageWindow(period: period, observations: observations, now: now)
            let localRows = repository.dailyUsage.filter {
                $0.accountID == accountID && window.containsUTCDay($0.date)
            }
            let server = accountID.flatMap { repository.accountUsage[$0] }
            let serverTokenCount = serverTokens(in: window, snapshot: server, period: period)
            let localTokens = localRows.reduce(Int64.zero) { $0 + $1.usage.totalTokens }
            let models = modelUsage(
                from: localRows,
                currentRateCard: rateCard,
                historicalRateCards: repository.rateCardRevisions
            )
            let daily = dailyUsage(
                from: localRows,
                currentRateCard: rateCard,
                historicalRateCards: repository.rateCardRevisions
            )
            var totals = sum(models.map(\.totals))
            if let serverTokenCount {
                totals = replacingTotalTokens(totals, with: serverTokenCount)
            }
            let quotaForecasts = CodexQuotaAnalytics.forecasts(
                observations: observations,
                latestLimits: accountID.flatMap { repository.latestLimits[$0] },
                now: now
            )
            let monthlyPrice = ChatGPTSubscriptionPresentationPolicy.monthlyPriceUSD(for: account.planType)
            if let monthlyPrice {
                knownSubscriptionTotal += monthlyPrice
                hasKnownSubscription = true
            }
            let tokensInBillingPeriod = accountID.flatMap { id in
                usageInBillingPeriod(account: account, server: repository.accountUsage[id])
            } ?? 0
            if monthlyPrice != nil { billingPeriodTokens += tokensInBillingPeriod }
            let effective = effectivePrice(subscriptionUSD: monthlyPrice, tokens: tokensInBillingPeriod)
            let coverage = serverTokenCount.flatMap { serverTokens in
                serverTokens > 0
                    ? UsageCoverage(observedTokens: localTokens, serverTokens: serverTokens)
                    : nil
            }
            let plan = ChatGPTSubscriptionPresentationPolicy.plan(for: account.planType)
            let observedAt = ([server?.observedAt] + quotaForecasts.map(\.forecast.latestObservationAt))
                .compactMap { $0 }
                .max()

            accountInsights.append(
                CodexAccountInsights(
                    id: accountID ?? "local:\(account.id.uuidString)",
                    localAccountID: account.id,
                    label: account.label,
                    email: account.email,
                    planTitle: plan.title,
                    monthlyPriceUSD: monthlyPrice,
                    quotaForecasts: quotaForecasts,
                    totals: totals,
                    effectiveSubscriptionUSDPerMillionTokens: effective,
                    models: models,
                    daily: daily,
                    coverage: coverage,
                    observedAt: observedAt
                )
            )
        }

        accountInsights.sort(by: riskOrder)
        let totals = sum(accountInsights.map(\.totals))
        let allModels = aggregateModels(from: accountInsights)
        let allDaily = aggregateDaily(from: accountInsights)
        let coverageValues = accountInsights.compactMap(\.coverage)
        let coverage = coverageValues.isEmpty ? nil : UsageCoverage(
            observedTokens: coverageValues.reduce(0) { $0 + $1.observedTokens },
            serverTokens: coverageValues.reduce(0) { $0 + $1.serverTokens }
        )
        let aggregateEffective = effectivePrice(
            subscriptionUSD: hasKnownSubscription ? knownSubscriptionTotal : nil,
            tokens: billingPeriodTokens
        )
        let nearestRisk = nearestQuotaRisk(in: accountInsights)
        let savedAccountIDs = Set(accounts.compactMap(\.accountId))
        let unattributedWindow = usageWindow(period: period, observations: [], now: now)
        let unattributedRows = repository.dailyUsage.filter { row in
            let belongsToSavedAccount = row.accountID.map(savedAccountIDs.contains) ?? false
            return !belongsToSavedAccount && unattributedWindow.containsUTCDay(row.date)
        }
        let unattributed = makeUnattributedInsights(
            rows: unattributedRows,
            window: unattributedWindow,
            rateCard: rateCard,
            historicalRateCards: repository.rateCardRevisions
        )

        return CodexInsightsSnapshot(
            period: period,
            generatedAt: now,
            accounts: accountInsights,
            totals: totals,
            models: allModels,
            daily: allDaily,
            nearestRisk: nearestRisk,
            totalMonthlySubscriptionUSD: hasKnownSubscription ? knownSubscriptionTotal : nil,
            effectiveSubscriptionUSDPerMillionTokens: aggregateEffective,
            coverage: coverage,
            unattributed: unattributed,
            priceChange: priceChange
        )
    }

    private static func usageWindow(
        period: CodexUsagePeriod,
        observations: [CodexLimitObservation],
        now: Date
    ) -> CodexUsageWindow {
        switch period {
        case .last30Days:
            return CodexUsageWindow(
                start: now.addingTimeInterval(-30 * 24 * 60 * 60),
                end: now.addingTimeInterval(1)
            )
        case .all:
            return CodexUsageWindow(start: .distantPast, end: now.addingTimeInterval(1))
        case .currentWeek:
            return CodexQuotaAnalytics.baseUsageWindow(observations: observations, now: now)
        }
    }

    private static func modelUsage(
        from rows: [CodexStoredDailyUsage],
        currentRateCard: OpenAIRateCardRevision,
        historicalRateCards: [OpenAIRateCardRevision]
    ) -> [CodexModelUsage] {
        Dictionary(grouping: rows, by: \.modelID)
            .map { model, rows in
                let priced = rows.map {
                    pricedTotals(
                        for: $0,
                        currentRateCard: currentRateCard,
                        historicalRateCards: historicalRateCards
                    )
                }
                return CodexModelUsage(modelID: model, totals: sum(priced))
            }
            .sorted(by: modelOrder)
    }

    private static func dailyUsage(
        from rows: [CodexStoredDailyUsage],
        currentRateCard: OpenAIRateCardRevision,
        historicalRateCards: [OpenAIRateCardRevision]
    ) -> [CodexDailyUsage] {
        Dictionary(grouping: rows, by: \.date)
            .map { date, rows in
                let priced = rows.map {
                    pricedTotals(
                        for: $0,
                        currentRateCard: currentRateCard,
                        historicalRateCards: historicalRateCards
                    )
                }
                return CodexDailyUsage(date: date, totals: sum(priced))
            }
            .sorted { $0.date < $1.date }
    }

    private static func aggregateModels(from accounts: [CodexAccountInsights]) -> [CodexModelUsage] {
        Dictionary(grouping: accounts.flatMap(\.models), by: \.modelID)
            .map { modelID, values in
                CodexModelUsage(modelID: modelID, totals: sum(values.map(\.totals)))
            }
            .sorted(by: modelOrder)
    }

    private static func aggregateDaily(from accounts: [CodexAccountInsights]) -> [CodexDailyUsage] {
        Dictionary(grouping: accounts.flatMap(\.daily), by: \.date)
            .map { date, values in
                CodexDailyUsage(date: date, totals: sum(values.map(\.totals)))
            }
            .sorted { $0.date < $1.date }
    }

    private static func makeUnattributedInsights(
        rows: [CodexStoredDailyUsage],
        window: CodexUsageWindow,
        rateCard: OpenAIRateCardRevision,
        historicalRateCards: [OpenAIRateCardRevision]
    ) -> CodexUnattributedInsights? {
        guard !rows.isEmpty else { return nil }
        let models = modelUsage(
            from: rows,
            currentRateCard: rateCard,
            historicalRateCards: historicalRateCards
        )
        return CodexUnattributedInsights(
            window: window,
            totals: sum(models.map(\.totals)),
            models: models,
            daily: dailyUsage(
                from: rows,
                currentRateCard: rateCard,
                historicalRateCards: historicalRateCards
            )
        )
    }

    private static func pricedTotals(
        for row: CodexStoredDailyUsage,
        currentRateCard: OpenAIRateCardRevision,
        historicalRateCards: [OpenAIRateCardRevision]
    ) -> CodexUsageTotals {
        let creditRevision = historicalRateCard(
            for: row,
            revisions: historicalRateCards,
            fallback: currentRateCard
        )
        let historical = CodexUsageCostCalculator.totals(
            for: row.usage,
            modelID: row.modelID,
            speed: row.speed,
            contextTier: row.contextTier,
            revision: creditRevision
        )
        let current = CodexUsageCostCalculator.totals(
            for: row.usage,
            modelID: row.modelID,
            speed: row.speed,
            contextTier: row.contextTier,
            revision: currentRateCard
        )
        return CodexUsageTotals(
            usage: row.usage,
            credits: historical.credits,
            apiEquivalentUSD: current.apiEquivalentUSD
        )
    }

    private static func historicalRateCard(
        for row: CodexStoredDailyUsage,
        revisions: [OpenAIRateCardRevision],
        fallback: OpenAIRateCardRevision
    ) -> OpenAIRateCardRevision {
        if let revisionID = row.rateRevisionID,
           let exact = revisions.first(where: { $0.id == revisionID }) {
            return exact
        }
        return OpenAIRateCardPolicy.effectiveRevision(at: row.date, revisions: revisions) ?? fallback
    }

    private static func sum(_ values: [CodexUsageTotals]) -> CodexUsageTotals {
        guard !values.isEmpty else {
            return CodexUsageTotals(usage: .zero, credits: nil, apiEquivalentUSD: nil)
        }
        let usage = values.reduce(CodexTokenUsage.zero) { $0 + $1.usage }
        let credits = values.allSatisfy { $0.credits != nil }
            ? values.compactMap(\.credits).reduce(0, +)
            : nil
        let api = values.allSatisfy { $0.apiEquivalentUSD != nil }
            ? values.compactMap(\.apiEquivalentUSD).reduce(0, +)
            : nil
        return CodexUsageTotals(usage: usage, credits: credits, apiEquivalentUSD: api)
    }

    private static func replacingTotalTokens(_ totals: CodexUsageTotals, with serverTokens: Int64) -> CodexUsageTotals {
        var usage = totals.usage
        usage.totalTokens = serverTokens
        return CodexUsageTotals(usage: usage, credits: totals.credits, apiEquivalentUSD: totals.apiEquivalentUSD)
    }

    private static func serverTokens(
        in window: CodexUsageWindow,
        snapshot: CodexAccountUsageSnapshot?,
        period: CodexUsagePeriod
    ) -> Int64? {
        guard let snapshot else { return nil }
        if period == .all, let lifetime = snapshot.summary.lifetimeTokens { return lifetime }
        return snapshot.dailyActivity
            .filter { window.containsUTCDay($0.date) }
            .reduce(Int64.zero) { $0 + $1.tokens }
    }

    private static func usageInBillingPeriod(
        account: StoredAccount,
        server: CodexAccountUsageSnapshot?
    ) -> Int64 {
        guard let start = account.subscriptionPeriod?.activeStart,
              let end = account.subscriptionPeriod?.activeUntil,
              end > start,
              let server else { return 0 }
        let window = CodexUsageWindow(start: start, end: end)
        return server.dailyActivity.filter { window.containsUTCDay($0.date) }.reduce(0) { $0 + $1.tokens }
    }

    private static func effectivePrice(subscriptionUSD: Decimal?, tokens: Int64) -> Decimal? {
        guard let subscriptionUSD, tokens > 0 else { return nil }
        return subscriptionUSD / (Decimal(tokens) / Decimal(1_000_000))
    }

    private static func nearestQuotaRisk(in accounts: [CodexAccountInsights]) -> CodexQuotaRisk? {
        let candidates = accounts.flatMap { account in
            account.quotaForecasts
                .filter { $0.forecast.state == .exhaustsBeforeReset }
                .map { (account.id, $0) }
        }
        guard let nearest = candidates.min(by: { lhs, rhs in
            if CodexQuotaForecast.riskOrder(lhs.1, rhs.1) { return true }
            if CodexQuotaForecast.riskOrder(rhs.1, lhs.1) { return false }
            return lhs.0 < rhs.0
        }) else { return nil }
        return CodexQuotaRisk(accountID: nearest.0, quotaKey: nearest.1.key)
    }

    private static func riskOrder(_ lhs: CodexAccountInsights, _ rhs: CodexAccountInsights) -> Bool {
        switch (lhs.riskiestQuotaForecast, rhs.riskiestQuotaForecast) {
        case let (left?, right?):
            if CodexQuotaForecast.riskOrder(left, right) { return true }
            if CodexQuotaForecast.riskOrder(right, left) { return false }
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none): break
        }
        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
    }

    private static func modelOrder(_ lhs: CodexModelUsage, _ rhs: CodexModelUsage) -> Bool {
        let left = lhs.totals.credits ?? -1
        let right = rhs.totals.credits ?? -1
        if left != right { return left > right }
        return lhs.modelID < rhs.modelID
    }
}
