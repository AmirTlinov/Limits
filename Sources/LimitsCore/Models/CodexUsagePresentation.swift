import Foundation

public enum CodexUsagePresentation {
    public static func makeSnapshot(
        accounts: [StoredAccount],
        repository: CodexUsageRepositorySnapshot,
        period: CodexUsagePeriod,
        rateCard: OpenAIRateCardRevision,
        priceChange: OpenAIPriceChange? = nil,
        now: Date = .now
    ) -> CodexInsightsSnapshot {
        let interval = usageInterval(period: period, repository: repository, now: now)
        var accountInsights: [CodexAccountInsights] = []
        var billingPeriodTokens: Int64 = 0
        var knownSubscriptionTotal = Decimal.zero
        var hasKnownSubscription = false

        for account in accounts {
            let accountID = account.accountId
            let localRows = repository.dailyUsage.filter {
                $0.accountID == accountID && interval.contains($0.date)
            }
            let server = accountID.flatMap { repository.accountUsage[$0] }
            let serverTokens = serverTokens(in: interval, snapshot: server, period: period)
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
            if serverTokens > 0 {
                totals = replacingTotalTokens(totals, with: serverTokens)
            }
            let forecast = accountID.flatMap { repository.limitObservations[$0] }.map {
                LimitBurnEstimator.forecast(observations: $0, now: now)
            } ?? LimitBurnEstimator.forecast(observations: [], now: now)
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
            let coverage = serverTokens > 0
                ? UsageCoverage(observedTokens: localTokens, serverTokens: serverTokens)
                : nil
            let plan = ChatGPTSubscriptionPresentationPolicy.plan(for: account.planType)
            let observedAt = [
                server?.observedAt,
                forecast.latestObservationAt,
            ].compactMap { $0 }.max()

            accountInsights.append(
                CodexAccountInsights(
                    id: accountID ?? "local:\(account.id.uuidString)",
                    localAccountID: account.id,
                    label: account.label,
                    email: account.email,
                    planTitle: plan.title,
                    monthlyPriceUSD: monthlyPrice,
                    forecast: forecast,
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
        let allLocalRows = repository.dailyUsage.filter { interval.contains($0.date) }
        let allModels = modelUsage(
            from: allLocalRows,
            currentRateCard: rateCard,
            historicalRateCards: repository.rateCardRevisions
        )
        let allDaily = dailyUsage(
            from: allLocalRows,
            currentRateCard: rateCard,
            historicalRateCards: repository.rateCardRevisions
        )
        var totals = sum(allModels.map(\.totals))
        let serverTotal = accounts.reduce(Int64.zero) { partial, account in
            guard let accountID = account.accountId else { return partial }
            return partial + serverTokens(in: interval, snapshot: repository.accountUsage[accountID], period: period)
        }
        if serverTotal > 0 { totals = replacingTotalTokens(totals, with: serverTotal) }
        let localTotal = allLocalRows.reduce(Int64.zero) { $0 + $1.usage.totalTokens }
        let coverage = serverTotal > 0
            ? UsageCoverage(observedTokens: localTotal, serverTokens: serverTotal)
            : nil
        let aggregateEffective = effectivePrice(
            subscriptionUSD: hasKnownSubscription ? knownSubscriptionTotal : nil,
            tokens: billingPeriodTokens
        )
        let nearestRisk = accountInsights.first { $0.forecast.state == .exhaustsBeforeReset }

        return CodexInsightsSnapshot(
            period: period,
            generatedAt: now,
            accounts: accountInsights,
            totals: totals,
            models: allModels,
            daily: allDaily,
            nearestRiskAccountID: nearestRisk?.id,
            totalMonthlySubscriptionUSD: hasKnownSubscription ? knownSubscriptionTotal : nil,
            effectiveSubscriptionUSDPerMillionTokens: aggregateEffective,
            coverage: coverage,
            priceChange: priceChange
        )
    }

    private static func usageInterval(
        period: CodexUsagePeriod,
        repository: CodexUsageRepositorySnapshot,
        now: Date
    ) -> DateInterval {
        switch period {
        case .last30Days:
            return DateInterval(start: now.addingTimeInterval(-30 * 24 * 60 * 60), end: now.addingTimeInterval(1))
        case .all:
            return DateInterval(start: .distantPast, end: now.addingTimeInterval(1))
        case .currentWeek:
            let weekly = repository.limitObservations.values
                .compactMap { LimitBurnEstimator.weeklySeries(from: $0)?.last }
                .filter { ($0.resetsAt ?? .distantPast) > now }
                .sorted { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }
                .first
            if let weekly, let reset = weekly.resetsAt, let minutes = weekly.windowDurationMinutes {
                return DateInterval(start: reset.addingTimeInterval(-TimeInterval(minutes * 60)), end: reset)
            }
            return DateInterval(start: now.addingTimeInterval(-7 * 24 * 60 * 60), end: now.addingTimeInterval(1))
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
            .sorted {
                let left = $0.totals.credits ?? -1
                let right = $1.totals.credits ?? -1
                if left != right { return left > right }
                return $0.modelID < $1.modelID
            }
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
        in interval: DateInterval,
        snapshot: CodexAccountUsageSnapshot?,
        period: CodexUsagePeriod
    ) -> Int64 {
        guard let snapshot else { return 0 }
        if period == .all, let lifetime = snapshot.summary.lifetimeTokens { return lifetime }
        return snapshot.dailyActivity
            .filter { interval.contains($0.date) }
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
        let interval = DateInterval(start: start, end: end)
        return server.dailyActivity.filter { interval.contains($0.date) }.reduce(0) { $0 + $1.tokens }
    }

    private static func effectivePrice(subscriptionUSD: Decimal?, tokens: Int64) -> Decimal? {
        guard let subscriptionUSD, tokens > 0 else { return nil }
        return subscriptionUSD / (Decimal(tokens) / Decimal(1_000_000))
    }

    private static func riskOrder(_ lhs: CodexAccountInsights, _ rhs: CodexAccountInsights) -> Bool {
        let leftRank = riskRank(lhs.forecast.state)
        let rightRank = riskRank(rhs.forecast.state)
        if leftRank != rightRank { return leftRank < rightRank }
        if lhs.forecast.predictedExhaustionAt != rhs.forecast.predictedExhaustionAt {
            return (lhs.forecast.predictedExhaustionAt ?? .distantFuture)
                < (rhs.forecast.predictedExhaustionAt ?? .distantFuture)
        }
        if lhs.forecast.remainingPercent != rhs.forecast.remainingPercent {
            return (lhs.forecast.remainingPercent ?? 101) < (rhs.forecast.remainingPercent ?? 101)
        }
        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
    }

    private static func riskRank(_ state: LimitBurnForecastState) -> Int {
        switch state {
        case .exhaustsBeforeReset: 0
        case .stable: 1
        case .collecting: 2
        case .stale: 3
        case .lastsUntilReset: 4
        }
    }
}
