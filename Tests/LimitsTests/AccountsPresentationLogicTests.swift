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

private func makeStoredAccount(label: String, status: AccountStatus = .ok) -> StoredAccount {
    let id = UUID()
    return StoredAccount(
        id: id,
        label: label,
        email: label,
        accountId: id.uuidString,
        planType: "pro",
        createdAt: .distantPast,
        updatedAt: .distantPast,
        lastValidatedAt: nil,
        status: status,
        statusMessage: nil,
        lastRateLimit: nil,
        lastRateLimitsByLimitId: nil,
        authFingerprint: "fingerprint-\(id.uuidString)",
        keychainAccount: "account.\(id.uuidString)"
    )
}
