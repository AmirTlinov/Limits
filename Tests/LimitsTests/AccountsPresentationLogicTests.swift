import Foundation
import Testing
@testable import LimitsCore
import LimitsShared

@Test func detailDestinationRoutesStoredClaudeAccount() {
    let claudeID = UUID()

    let destination = AccountsPresentationLogic.detailDestination(
        selectionRaw: "claude-account:\(claudeID.uuidString)",
        codexAccountIDs: [],
        claudeAccountIDs: [claudeID]
    )

    #expect(destination == .claudeAccount(claudeID))
}

@Test func detailDestinationFallsBackWhenClaudeAccountIsMissing() {
    let destination = AccountsPresentationLogic.detailDestination(
        selectionRaw: "claude-account:\(UUID().uuidString)",
        codexAccountIDs: [],
        claudeAccountIDs: []
    )

    #expect(destination == .currentClaudeCode)
}

@Test func storedAccountRowsScrollOnlyAfterThreshold() {
    #expect(
        !AccountsPresentationLogic.needsStoredAccountsScroll(
            storedCodexCount: 2,
            storedClaudeCount: 2
        )
    )
    #expect(
        AccountsPresentationLogic.needsStoredAccountsScroll(
            storedCodexCount: 3,
            storedClaudeCount: 2
        )
    )
}

@Test func sidebarFilterVisibilityMatchesProvider() {
    let codexID = UUID()
    let claudeID = UUID()
    let catalog = ProviderCatalogSnapshot(savedClaudeCount: 1, claudeSource: .loggedOut)

    #expect(
        AccountsPresentationLogic.isVisible(
            destination: .currentCodexCLI,
            filter: .codex,
            catalog: catalog
        )
    )
    #expect(
        AccountsPresentationLogic.isVisible(
            destination: .codexAccount(codexID),
            filter: .codex,
            catalog: catalog
        )
    )
    #expect(
        !AccountsPresentationLogic.isVisible(
            destination: .claudeAccount(claudeID),
            filter: .codex,
            catalog: catalog
        )
    )
    #expect(
        AccountsPresentationLogic.isVisible(
            destination: .currentClaudeCode,
            filter: .claude,
            catalog: catalog
        )
    )
    #expect(
        !AccountsPresentationLogic.isVisible(
            destination: .codexAccount(codexID),
            filter: .claude,
            catalog: catalog
        )
    )
    #expect(
        AccountsPresentationLogic.isVisible(
            destination: .claudeAccount(claudeID),
            filter: .all,
            catalog: catalog
        )
    )
}

@Test func sidebarFilterDefaultDestinationMatchesProvider() {
    let catalog = ProviderCatalogSnapshot(savedClaudeCount: 1, claudeSource: .loggedOut)
    #expect(AccountsPresentationLogic.defaultDestination(for: .all, catalog: catalog) == .currentCodexCLI)
    #expect(AccountsPresentationLogic.defaultDestination(for: .codex, catalog: catalog) == .currentCodexCLI)
    #expect(AccountsPresentationLogic.defaultDestination(for: .claude, catalog: catalog) == .currentClaudeCode)
}

@Test func sidebarFilterIncludesExpectedProviders() {
    #expect(AccountsSidebarFilter.all.includesCodex)
    #expect(AccountsSidebarFilter.all.includesClaude)
    #expect(AccountsSidebarFilter.codex.includesCodex)
    #expect(!AccountsSidebarFilter.codex.includesClaude)
    #expect(!AccountsSidebarFilter.claude.includesCodex)
    #expect(AccountsSidebarFilter.claude.includesClaude)
}

@Test func trayStatusProviderFollowsSelectedProvider() {
    #expect(AccountsSidebarFilter.all.trayStatusProvider == .codex)
    #expect(AccountsSidebarFilter.codex.trayStatusProvider == .codex)
    #expect(AccountsSidebarFilter.claude.trayStatusProvider == .claude)
    #expect(TrayStatusProvider.codex.displayTitle == "Codex")
    #expect(TrayStatusProvider.claude.displayTitle == "Claude")
}

@Test func codexSidebarSortUsesResetTimeThenRemainingLimits() throws {
    let calendar = Calendar.current
    let soon = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 17)))
    let later = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 18)))
    let soonAccount = makeStoredAccount(label: "soon@example.com")
    let laterAccount = makeStoredAccount(label: "later@example.com")
    let noDataAccount = makeStoredAccount(label: "none@example.com", status: .validationFailed)

    let sorted = CodexAccountsPresentationPolicy.sortedForSidebar(
        [noDataAccount, laterAccount, soonAccount],
        summaries: [
            soonAccount.id: SidebarLimitSummary(
                fiveHourRemainingPercent: 40,
                weeklyRemainingPercent: 80,
                nextResetDate: soon
            ),
            laterAccount.id: SidebarLimitSummary(
                fiveHourRemainingPercent: 99,
                weeklyRemainingPercent: 99,
                nextResetDate: later
            ),
            noDataAccount.id: nil,
        ]
    )

    #expect(sorted.map(\.id) == [soonAccount.id, laterAccount.id, noDataAccount.id])
}

@Test func codexSidebarSortUsesRemainingLimitsAsTieBreaker() throws {
    let calendar = Calendar.current
    let sameReset = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 17)))
    let fuller = makeStoredAccount(label: "fuller@example.com")
    let lower = makeStoredAccount(label: "lower@example.com")

    let sorted = CodexAccountsPresentationPolicy.sortedForSidebar(
        [lower, fuller],
        summaries: [
            fuller.id: SidebarLimitSummary(
                fiveHourRemainingPercent: 80,
                weeklyRemainingPercent: 90,
                nextResetDate: sameReset
            ),
            lower.id: SidebarLimitSummary(
                fiveHourRemainingPercent: 80,
                weeklyRemainingPercent: 10,
                nextResetDate: sameReset
            ),
        ]
    )

    #expect(sorted.map(\.id) == [fuller.id, lower.id])
}


@Test func codexCurrentProbeTTLDoesNotReuseSnapshotAfterResetPassed() throws {
    let calendar = Calendar.current
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 16)))
    let pastReset = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 15, minute: 59)))
    let futureReset = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 17)))

    let staleProbe = CodexSessionProbe(
        fingerprint: "fingerprint",
        email: "user@example.com",
        planType: "pro",
        rateLimit: makeRateLimitSnapshot(resetDate: pastReset, usedPercent: 95),
        rateLimitsByLimitId: nil,
        validatedAt: now.addingTimeInterval(-30)
    )
    let freshProbe = CodexSessionProbe(
        fingerprint: "fingerprint",
        email: "user@example.com",
        planType: "pro",
        rateLimit: makeRateLimitSnapshot(resetDate: futureReset, usedPercent: 10),
        rateLimitsByLimitId: nil,
        validatedAt: now.addingTimeInterval(-30)
    )

    #expect(!CodexRefreshPolicy.canReuse(staleProbe, expectedFingerprint: "fingerprint", now: now, ttl: 300))
    #expect(CodexRefreshPolicy.canReuse(freshProbe, expectedFingerprint: "fingerprint", now: now, ttl: 300))
}

@Test func currentExpiredResetRefreshUsesBackoffInsteadOfThirtySecondPolling() throws {
    let calendar = Calendar.current
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 16)))
    let lastAttempt = now.addingTimeInterval(-30)

    #expect(CodexRefreshPolicy.canAttemptRefresh(lastAttempt: nil, now: now, retryInterval: 300))
    #expect(!CodexRefreshPolicy.canAttemptRefresh(lastAttempt: lastAttempt, now: now, retryInterval: 300))
    #expect(CodexRefreshPolicy.canAttemptRefresh(lastAttempt: now.addingTimeInterval(-301), now: now, retryInterval: 300))
}

@Test func weeklyOnlyResetInvalidatesCurrentAndStoredSnapshots() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let weeklyOnly = RateLimitSnapshotModel(
        credits: nil,
        limitId: "codex",
        limitName: nil,
        planType: "pro",
        primary: RateLimitWindowSnapshot(
            resetsAt: Int64(now.addingTimeInterval(-1).timeIntervalSince1970),
            usedPercent: 100,
            windowDurationMins: 10_080
        ),
        rateLimitReachedType: nil,
        secondary: nil
    )
    let probe = CodexSessionProbe(
        fingerprint: "fingerprint",
        email: "user@example.com",
        planType: "pro",
        rateLimit: weeklyOnly,
        rateLimitsByLimitId: ["codex": weeklyOnly],
        validatedAt: now.addingTimeInterval(-30)
    )
    let account = makeStoredAccount(
        label: "weekly@example.com",
        lastRateLimit: weeklyOnly,
        lastValidatedAt: now.addingTimeInterval(-30)
    )

    #expect(!CodexRefreshPolicy.canReuse(probe, expectedFingerprint: "fingerprint", now: now))
    #expect(CodexRefreshPolicy.accountNeedsRefresh(account, now: now))
}

@Test func spendControlResetBoundaryAlsoRequestsRefresh() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let snapshot = RateLimitSnapshotModel(
        credits: nil,
        limitId: "codex",
        limitName: nil,
        planType: "business",
        primary: nil,
        rateLimitReachedType: nil,
        secondary: nil,
        spendControlReached: true,
        individualLimit: SpendControlLimitSnapshot(
            limit: "100",
            remainingPercent: 0,
            resetsAt: Int64(now.addingTimeInterval(-1).timeIntervalSince1970),
            used: "100"
        )
    )

    #expect(CodexRefreshPolicy.snapshotHasPassedReset(primary: snapshot, byLimitId: nil, now: now))
}

@Test func failedLimitProbeUsesShortBackoffInsteadOfFreshTTL() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let probe = CodexSessionProbe(
        fingerprint: "fingerprint",
        email: "user@example.com",
        planType: "pro",
        rateLimit: nil,
        rateLimitsByLimitId: nil,
        validatedAt: now.addingTimeInterval(-30),
        rateLimitError: "temporary backend outage"
    )

    #expect(!CodexRefreshPolicy.canReuse(probe, expectedFingerprint: "fingerprint", now: now))
    #expect(!CodexRefreshPolicy.canAttemptRefresh(lastAttempt: now.addingTimeInterval(-30), now: now, retryInterval: 300))
    #expect(CodexRefreshPolicy.canAttemptRefresh(lastAttempt: now.addingTimeInterval(-301), now: now, retryInterval: 300))
}

@Test func authTokenFailuresRequireReauthInsteadOfGenericValidationFailure() {
    #expect(AccountResolution.validationStatus(forErrorMessage: "401 Unauthorized") == .needsReauth)
    #expect(AccountResolution.validationStatus(forErrorMessage: "token_expired") == .needsReauth)
    #expect(AccountResolution.validationStatus(forErrorMessage: "token_invalidated") == .needsReauth)
    #expect(AccountResolution.validationStatus(forErrorMessage: "refresh token was already used") == .needsReauth)
    #expect(AccountResolution.validationStatus(forErrorMessage: "temporary backend outage") == .validationFailed)
}

@Test func currentCLIProbeNoteCollapsesRawAuthErrorsIntoUserStatus() {
    L10n.withLanguage("ru") {
        #expect(CodexSessionPresentation.probeNote(for: "401 Unauthorized token_invalidated") == "Текущей авторизации нужен повторный вход.")
        #expect(CodexSessionPresentation.probeNote(for: "temporary backend outage") == "Не удалось обновить живые лимиты.")
    }
}

@Test func storedCodexAutoRefreshPicksStaleAccountWithoutRetryHammering() throws {
    let calendar = Calendar.current
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 16)))
    let pastReset = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 15)))
    let futureReset = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 17)))

    let current = makeStoredAccount(label: "current@example.com", lastRateLimit: makeRateLimitSnapshot(resetDate: pastReset, usedPercent: 100))
    let throttled = makeStoredAccount(label: "throttled@example.com", lastRateLimit: makeRateLimitSnapshot(resetDate: pastReset, usedPercent: 100))
    let candidate = makeStoredAccount(label: "candidate@example.com", lastRateLimit: makeRateLimitSnapshot(resetDate: pastReset, usedPercent: 100))
    let fresh = makeStoredAccount(label: "fresh@example.com", lastRateLimit: makeRateLimitSnapshot(resetDate: futureReset, usedPercent: 10))
    let reauth = makeStoredAccount(label: "reauth@example.com", status: .needsReauth, lastRateLimit: makeRateLimitSnapshot(resetDate: pastReset, usedPercent: 100))

    let selected = CodexRefreshPolicy.nextStoredAccountID(
        accounts: [fresh, current, throttled, candidate, reauth],
        currentAccountID: current.id,
        lastAttempts: [throttled.id: now.addingTimeInterval(-120)],
        now: now,
        retryInterval: 1_800
    )

    #expect(selected == candidate.id)
}

@Test func storedCodexAutoRefreshAlsoRetriesEmptyFailedAccountsWithBackoff() throws {
    let calendar = Calendar.current
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 16)))
    let emptyFailed = makeStoredAccount(label: "empty@example.com", status: .validationFailed)
    let emptyNeedsReauth = makeStoredAccount(label: "reauth@example.com", status: .needsReauth)
    let throttledEmpty = makeStoredAccount(label: "throttled@example.com", status: .validationFailed)

    let selected = CodexRefreshPolicy.nextStoredAccountID(
        accounts: [emptyNeedsReauth, throttledEmpty, emptyFailed],
        currentAccountID: nil,
        lastAttempts: [throttledEmpty.id: now.addingTimeInterval(-120)],
        now: now,
        retryInterval: 1_800
    )

    #expect(selected == emptyFailed.id)
}

@Test func openingSurfaceRefreshesOldStoredAccountsButKeepsRecentOnesCached() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let futureReset = now.addingTimeInterval(3_600)
    let old = makeStoredAccount(
        label: "old@example.com",
        lastRateLimit: makeRateLimitSnapshot(resetDate: futureReset, usedPercent: 20),
        lastValidatedAt: now.addingTimeInterval(-LimitsFreshnessPolicy.defaultTTL - 1)
    )
    let recent = makeStoredAccount(
        label: "recent@example.com",
        lastRateLimit: makeRateLimitSnapshot(resetDate: futureReset, usedPercent: 20),
        lastValidatedAt: now.addingTimeInterval(-60)
    )

    let selected = CodexRefreshPolicy.nextStoredAccountID(
        accounts: [recent, old],
        currentAccountID: nil,
        lastAttempts: [:],
        now: now,
        retryInterval: 300,
        maximumAge: LimitsFreshnessPolicy.defaultTTL
    )

    #expect(selected == old.id)
    #expect(!CodexRefreshPolicy.accountNeedsRefresh(recent, now: now, maximumAge: LimitsFreshnessPolicy.defaultTTL))
}

@Test func trayStatusSegmentsUseProviderIconsWithCompactMetrics() {
    let codex = TrayProviderAvailability(remainingPercent: 96, availableAccounts: 1, totalAccounts: 8)
    let claude = TrayProviderAvailability(remainingPercent: 95, availableAccounts: 1, totalAccounts: 2)
    let noData = TrayProviderAvailability(remainingPercent: nil, availableAccounts: 0, totalAccounts: 8)
    let catalog = ProviderCatalogSnapshot(savedClaudeCount: 1, claudeSource: .loggedOut)

    #expect(TrayStatusPresentation.segments(filter: .all, catalog: catalog, codex: codex, claude: claude) == [
        TrayStatusPresentationSegment(provider: .codex, metricText: "96% 1/8", remainingPercent: 96),
        TrayStatusPresentationSegment(provider: .claude, metricText: "95% 1/2", remainingPercent: 95),
    ])
    #expect(TrayStatusPresentation.segments(filter: .codex, catalog: catalog, codex: noData, claude: claude) == [
        TrayStatusPresentationSegment(provider: .codex, metricText: "— 0/8", remainingPercent: nil),
    ])
    #expect(TrayStatusPresentation.title(filter: .all, catalog: catalog, codex: codex, claude: claude) == "Codex 96% 1/8 · Claude 95% 1/2")
    #expect(TrayStatusPresentation.title(filter: .codex, catalog: catalog, codex: codex, claude: claude) == "Codex 96% 1/8")
    #expect(TrayStatusPresentation.title(filter: .codex, catalog: catalog, codex: noData, claude: claude) == "Codex — 0/8")
}

@Test func providerPresentationKeepsBadgesAndAccountCountsConsistent() {
    #expect(ProviderPresentation.currentCodexCountsAsAccount(.stored(UUID())))
    #expect(ProviderPresentation.currentCodexCountsAsAccount(.external("acct_123")))
    #expect(!ProviderPresentation.currentCodexCountsAsAccount(.missing))
    #expect(!ProviderPresentation.currentCodexCountsAsAccount(.unreadable))

    #expect(ProviderPresentation.currentClaudeCountsAsAccount(.stored(UUID())))
    #expect(ProviderPresentation.currentClaudeCountsAsAccount(.external("user@example.com")))
    #expect(!ProviderPresentation.currentClaudeCountsAsAccount(.loggedOut))
    #expect(!ProviderPresentation.currentClaudeCountsAsAccount(.notInstalled))
    #expect(!ProviderPresentation.currentClaudeCountsAsAccount(.unreadable))

    #expect(ProviderPresentation.codexBadge(source: .stored(UUID())).tone == .codex)
    #expect(ProviderPresentation.codexBadge(source: .unreadable).tone == .danger)
    #expect(ProviderPresentation.claudeBadge(source: .external("user@example.com")).tone == .claude)
    #expect(ProviderPresentation.accountBadge(status: .limitReached, isCurrent: false, provider: .codex).tone == .warning)
    #expect(ProviderPresentation.accountBadge(status: .ok, isCurrent: true, provider: .claude).tone == .claude)
}

@Test func trayStatusSnapshotCarriesMetricTooltipAndAccessibilityText() {
    let codex = TrayProviderAvailability(remainingPercent: 96, availableAccounts: 1, totalAccounts: 8)
    let claude = TrayProviderAvailability(remainingPercent: nil, availableAccounts: 0, totalAccounts: 2)
    let catalog = ProviderCatalogSnapshot(savedClaudeCount: 1, claudeSource: .loggedOut)
    let snapshot = TrayStatusPresentation.snapshot(
        filter: .all,
        catalog: catalog,
        codex: codex,
        claude: claude,
        codexLimit: TrayLimitSnapshot(remainingPercent: 96, resetText: "Reset 18:00"),
        claudeLimit: TrayLimitSnapshot(remainingPercent: nil, resetText: nil)
    )

    #expect(snapshot.title == "Codex 96% 1/8 · Claude — 0/2")
    #expect(snapshot.tooltip.contains("Codex"))
    #expect(snapshot.tooltip.contains("Reset 18:00"))
    #expect(snapshot.tooltip.contains("1/8"))
    #expect(snapshot.accessibilityLabel.contains("Codex"))
    #expect(snapshot.accessibilityLabel.contains("Claude"))
    #expect(snapshot == TrayStatusPresentation.snapshot(
        filter: .all,
        catalog: catalog,
        codex: codex,
        claude: claude,
        codexLimit: TrayLimitSnapshot(remainingPercent: 96, resetText: "Reset 18:00"),
        claudeLimit: TrayLimitSnapshot(remainingPercent: nil, resetText: nil)
    ))
}

@Test func claudeMissingCredentialUsesClaudeSpecificLocalizationKey() {
    L10n.withLanguage("en") {
        #expect(GlobalClaudeCredentialServiceError.missingCredential.localizedDescription == "Current Claude Code authorization was not found in Keychain.")
        #expect(GlobalClaudeCredentialServiceError.unexpectedStatus(-50).localizedDescription == "Claude Code Keychain returned error -50.")
        #expect(L10n.tr("codex.auth.keychain_missing") == "codex.auth.keychain_missing")
    }
}

@Test func codexSidebarLimitSummaryCompactsFiveHourAndWeeklyWithoutExtraRows() {
    L10n.withLanguage("ru") {
        let summary = SidebarLimitSummary(
            fiveHourRemainingPercent: 98,
            weeklyRemainingPercent: 99,
            nextResetDate: nil
        )

        #expect(summary.compactLimitText() == "5ч 98% · 7д 99%")
    }
}

private func makeStoredAccount(
    label: String,
    status: AccountStatus = .ok,
    lastRateLimit: RateLimitSnapshotModel? = nil,
    lastValidatedAt: Date? = nil
) -> StoredAccount {
    let id = UUID()
    return StoredAccount(
        id: id,
        label: label,
        email: label,
        accountId: id.uuidString,
        planType: "pro",
        createdAt: .distantPast,
        updatedAt: .distantPast,
        lastValidatedAt: lastValidatedAt,
        status: status,
        statusMessage: nil,
        lastRateLimit: lastRateLimit,
        lastRateLimitsByLimitId: nil,
        authFingerprint: "fingerprint-\(id.uuidString)",
        keychainAccount: "account.\(id.uuidString)",
        lastRateLimitObservedAt: lastValidatedAt
    )
}

private func makeRateLimitSnapshot(resetDate: Date, usedPercent: Int) -> RateLimitSnapshotModel {
    RateLimitSnapshotModel(
        credits: nil,
        limitId: "codex",
        limitName: nil,
        planType: "pro",
        primary: RateLimitWindowSnapshot(
            resetsAt: Int64(resetDate.timeIntervalSince1970),
            usedPercent: usedPercent,
            windowDurationMins: 300
        ),
        rateLimitReachedType: nil,
        secondary: RateLimitWindowSnapshot(
            resetsAt: Int64(resetDate.addingTimeInterval(7 * 24 * 60 * 60).timeIntervalSince1970),
            usedPercent: min(usedPercent, 99),
            windowDurationMins: 10_080
        )
    )
}
