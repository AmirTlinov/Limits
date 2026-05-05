import Foundation
import Testing
@testable import Limits

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

@Test func currentClaudeVisibilityMatchesStateAndStoredAccounts() {
    #expect(
        AccountsPresentationLogic.shouldShowCurrentClaude(
            source: .stored(UUID()),
            storedClaudeCount: 0
        )
    )
    #expect(
        AccountsPresentationLogic.shouldShowCurrentClaude(
            source: .external("user@example.com"),
            storedClaudeCount: 0
        )
    )
    #expect(
        AccountsPresentationLogic.shouldShowCurrentClaude(
            source: .loggedOut,
            storedClaudeCount: 0
        )
    )
    #expect(
        !AccountsPresentationLogic.shouldShowCurrentClaude(
            source: .notInstalled,
            storedClaudeCount: 0
        )
    )
    #expect(
        AccountsPresentationLogic.shouldShowCurrentClaude(
            source: .notInstalled,
            storedClaudeCount: 1
        )
    )
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

    #expect(
        AccountsPresentationLogic.isVisible(
            destination: .currentCodexCLI,
            filter: .codex
        )
    )
    #expect(
        AccountsPresentationLogic.isVisible(
            destination: .codexAccount(codexID),
            filter: .codex
        )
    )
    #expect(
        !AccountsPresentationLogic.isVisible(
            destination: .claudeAccount(claudeID),
            filter: .codex
        )
    )
    #expect(
        AccountsPresentationLogic.isVisible(
            destination: .currentClaudeCode,
            filter: .claude
        )
    )
    #expect(
        !AccountsPresentationLogic.isVisible(
            destination: .codexAccount(codexID),
            filter: .claude
        )
    )
    #expect(
        AccountsPresentationLogic.isVisible(
            destination: .claudeAccount(claudeID),
            filter: .all
        )
    )
}

@Test func sidebarFilterDefaultDestinationMatchesProvider() {
    #expect(AccountsPresentationLogic.defaultDestination(for: .all) == .currentCodexCLI)
    #expect(AccountsPresentationLogic.defaultDestination(for: .codex) == .currentCodexCLI)
    #expect(AccountsPresentationLogic.defaultDestination(for: .claude) == .currentClaudeCode)
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

    let sorted = AppModel.sortedCodexAccountsForSidebar(
        [noDataAccount, laterAccount, soonAccount],
        summaries: [
            soonAccount.id: AppModel.SidebarLimitSummary(
                fiveHourRemainingPercent: 40,
                weeklyRemainingPercent: 80,
                nextResetDate: soon
            ),
            laterAccount.id: AppModel.SidebarLimitSummary(
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

    let sorted = AppModel.sortedCodexAccountsForSidebar(
        [lower, fuller],
        summaries: [
            fuller.id: AppModel.SidebarLimitSummary(
                fiveHourRemainingPercent: 80,
                weeklyRemainingPercent: 90,
                nextResetDate: sameReset
            ),
            lower.id: AppModel.SidebarLimitSummary(
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

    let staleProbe = AppModel.CurrentCLIProbe(
        fingerprint: "fingerprint",
        email: "user@example.com",
        planType: "pro",
        rateLimit: makeRateLimitSnapshot(resetDate: pastReset, usedPercent: 95),
        rateLimitsByLimitId: nil,
        validatedAt: now.addingTimeInterval(-30)
    )
    let freshProbe = AppModel.CurrentCLIProbe(
        fingerprint: "fingerprint",
        email: "user@example.com",
        planType: "pro",
        rateLimit: makeRateLimitSnapshot(resetDate: futureReset, usedPercent: 10),
        rateLimitsByLimitId: nil,
        validatedAt: now.addingTimeInterval(-30)
    )

    #expect(!AppModel.currentCLIProbeCanBeReused(staleProbe, expectedFingerprint: "fingerprint", now: now, ttl: 300))
    #expect(AppModel.currentCLIProbeCanBeReused(freshProbe, expectedFingerprint: "fingerprint", now: now, ttl: 300))
}

@Test func currentExpiredResetRefreshUsesBackoffInsteadOfThirtySecondPolling() throws {
    let calendar = Calendar.current
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 5, day: 5, hour: 16)))
    let lastAttempt = now.addingTimeInterval(-30)

    #expect(AppModel.canAttemptExpiredResetRefresh(lastAttempt: nil, now: now, retryInterval: 300))
    #expect(!AppModel.canAttemptExpiredResetRefresh(lastAttempt: lastAttempt, now: now, retryInterval: 300))
    #expect(AppModel.canAttemptExpiredResetRefresh(lastAttempt: now.addingTimeInterval(-301), now: now, retryInterval: 300))
}

@Test func authTokenFailuresRequireReauthInsteadOfGenericValidationFailure() {
    #expect(AppModel.validationStatus(forErrorMessage: "401 Unauthorized") == .needsReauth)
    #expect(AppModel.validationStatus(forErrorMessage: "token_expired") == .needsReauth)
    #expect(AppModel.validationStatus(forErrorMessage: "token_invalidated") == .needsReauth)
    #expect(AppModel.validationStatus(forErrorMessage: "refresh token was already used") == .needsReauth)
    #expect(AppModel.validationStatus(forErrorMessage: "temporary backend outage") == .validationFailed)
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

    let selected = AppModel.nextStoredCodexAccountIDForAutoRefresh(
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

    let selected = AppModel.nextStoredCodexAccountIDForAutoRefresh(
        accounts: [emptyNeedsReauth, throttledEmpty, emptyFailed],
        currentAccountID: nil,
        lastAttempts: [throttledEmpty.id: now.addingTimeInterval(-120)],
        now: now,
        retryInterval: 1_800
    )

    #expect(selected == emptyFailed.id)
}

@Test func trayStatusSegmentsUseProviderIconsWithCompactMetrics() {
    let codex = TrayProviderAvailability(remainingPercent: 96, availableAccounts: 1, totalAccounts: 8)
    let claude = TrayProviderAvailability(remainingPercent: 95, availableAccounts: 1, totalAccounts: 2)
    let noData = TrayProviderAvailability(remainingPercent: nil, availableAccounts: 0, totalAccounts: 8)

    #expect(TrayStatusPresentation.segments(filter: .all, codex: codex, claude: claude) == [
        TrayStatusPresentationSegment(provider: .codex, metricText: "96% 1/8", remainingPercent: 96),
        TrayStatusPresentationSegment(provider: .claude, metricText: "95% 1/2", remainingPercent: 95),
    ])
    #expect(TrayStatusPresentation.segments(filter: .codex, codex: noData, claude: claude) == [
        TrayStatusPresentationSegment(provider: .codex, metricText: "— 0/8", remainingPercent: nil),
    ])
    #expect(TrayStatusPresentation.title(filter: .all, codex: codex, claude: claude) == "Codex 96% 1/8 · Claude 95% 1/2")
    #expect(TrayStatusPresentation.title(filter: .codex, codex: codex, claude: claude) == "Codex 96% 1/8")
    #expect(TrayStatusPresentation.title(filter: .codex, codex: noData, claude: claude) == "Codex — 0/8")
}

@Test func trayProviderIconsAreRealSvgResources() throws {
    for provider in [TrayStatusProvider.codex, .claude] {
        let url = try #require(TrayStatusIconAsset.resourceURL(for: provider))
        let svg = try String(contentsOf: url, encoding: .utf8)

        #expect(svg.contains("<svg"))
        #expect(!svg.contains("<image"))
        #expect(!svg.localizedCaseInsensitiveContains("data:image"))
    }
}

@Test func codexSidebarLimitSummaryCompactsFiveHourAndWeeklyWithoutExtraRows() {
    L10n.withLanguage("ru") {
        let summary = AppModel.SidebarLimitSummary(
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
        keychainAccount: "account.\(id.uuidString)"
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
