import Foundation
import Testing
@testable import LimitsCore

@Test func claudeAppearsOnlyForSavedAccountOrLiveStableIdentity() {
    let hiddenSources: [ClaudeSessionSource] = [.notInstalled, .loggedOut, .unreadable]
    for source in hiddenSources {
        let catalog = ProviderCatalogSnapshot(savedClaudeCount: 0, claudeSource: source)
        #expect(catalog.providers == [.codex])
        #expect(catalog.normalized(.claude) == .codex)
    }

    #expect(ProviderCatalogSnapshot(savedClaudeCount: 0, claudeSource: .external("user@example.com")).providers == [.codex, .claude])
    #expect(ProviderCatalogSnapshot(savedClaudeCount: 1, claudeSource: .loggedOut).providers == [.codex, .claude])
}

@Test func hiddenClaudeIsAbsentFromTrayCatalogAndStoredFilter() {
    let catalog = ProviderCatalogSnapshot(savedClaudeCount: 0, claudeSource: .loggedOut)
    let codex = TrayProviderAvailability(remainingPercent: 50, availableAccounts: 1, totalAccounts: 1)
    let claude = TrayProviderAvailability(remainingPercent: 90, availableAccounts: 1, totalAccounts: 1)
    let snapshot = TrayStatusPresentation.snapshot(
        filter: .claude,
        catalog: catalog,
        codex: codex,
        claude: claude,
        codexLimit: TrayLimitSnapshot(remainingPercent: 50, resetText: nil),
        claudeLimit: TrayLimitSnapshot(remainingPercent: 90, resetText: nil)
    )

    #expect(snapshot.filter == .codex)
    #expect(snapshot.segments.map(\.provider) == [.codex])
    #expect(!snapshot.title.contains("Claude"))
    #expect(!snapshot.tooltip.contains("Claude"))
    #expect(!snapshot.accessibilityLabel.contains("Claude"))
    #expect(catalog.filterOptions == [.all, .codex])
    #expect(catalog.trayProviders == [.codex])
    #expect(catalog.widgetProviderIDs == [.codex])
}

@Test func everySurfaceProjectsTheSameVisibleProviderOrder() {
    let catalog = ProviderCatalogSnapshot(savedClaudeCount: 1, claudeSource: .loggedOut)
    #expect(catalog.providers == [.codex, .claude])
    #expect(catalog.filterOptions == [.all, .codex, .claude])
    #expect(catalog.trayProviders == [.codex, .claude])
    #expect(catalog.widgetProviderIDs == [.codex, .claude])
}

@Test func claudeEvidenceOmitsWindowWithoutUsedPercentage() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let identity = ClaudeAccountIdentity(email: "user@example.com", organizationId: "org-a")!
    let evidence = ClaudeLiveEvidence(
        identity: identity,
        identityChangedAt: now.addingTimeInterval(-60),
        snapshot: ClaudeStatuslineBridgeSnapshot(
            fiveHour: .init(usedPercentage: nil, resetsAt: Int64(now.timeIntervalSince1970 + 300)),
            sevenDay: .init(usedPercentage: 40, resetsAt: Int64(now.timeIntervalSince1970 + 600))
        ),
        snapshotAt: now.addingTimeInterval(-10)
    )

    let rows = ClaudeLivePresentation.rateLimitSections(evidence: evidence, now: now).flatMap(\.rows)
    #expect(rows.map(\.id) == ["claude.seven_day"])
    #expect(rows.first?.remainingPercent == 60)
    #expect(ClaudeLivePresentation.rateLimitSections(evidence: evidence, now: now.addingTimeInterval(901)).isEmpty)
}

@Test func spendControlReachedMakesCodexAccountUnavailableEvenBelowRateLimit() {
    let snapshot = RateLimitSnapshotModel(
        credits: nil,
        limitId: "codex",
        limitName: nil,
        planType: "pro",
        primary: RateLimitWindowSnapshot(resetsAt: nil, usedPercent: 10, windowDurationMins: 300),
        rateLimitReachedType: nil,
        secondary: nil,
        spendControlReached: true,
        individualLimit: SpendControlLimitSnapshot(limit: "20", remainingPercent: 0, resetsAt: 2_000_000, used: "20")
    )
    #expect(snapshot.isReached)
}

@Test func individualSpendLimitProducesAStableVisibleRow() throws {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let snapshot = RateLimitSnapshotModel(
        credits: nil,
        limitId: "codex",
        limitName: nil,
        planType: "pro",
        primary: nil,
        rateLimitReachedType: nil,
        secondary: nil,
        individualLimit: SpendControlLimitSnapshot(
            limit: "$50",
            remainingPercent: 70,
            resetsAt: Int64(now.timeIntervalSince1970 + 600),
            used: "$15"
        )
    )

    let row = try #require(
        RateLimitDisplayBuilder.makeSections(
            primary: snapshot,
            byLimitId: nil,
            excludingExpiredRowsAt: now
        ).first?.rows.first
    )
    #expect(row.id == "codex.individual")
    #expect(row.usedPercent == 30)
    #expect(row.remainingPercent == 70)
}

@Test func migrationKeepsSameClaudeEmailInDifferentOrganizationsSeparate() {
    let first = claudeAccount(email: "same@example.com", orgID: "org-a", fingerprint: "a")
    let second = claudeAccount(email: "SAME@example.com", orgID: "org-b", fingerprint: "b")
    let result = PersistedStateMigrator.migrate(
        PersistedStateV5(schemaVersion: 2, accounts: [], claudeAccounts: [first, second]),
        currentCodexFingerprint: nil,
        currentClaudeFingerprint: nil
    )
    #expect(result.state.claudeAccounts.count == 2)
    #expect(Set(result.state.claudeAccounts.compactMap(\.orgId)) == ["org-a", "org-b"])
}

@Test func legacyClaudeAccountPromotesOnlyWithUnambiguousIdentityEvidence() {
    let legacy = claudeAccount(email: "same@example.com", orgID: nil, fingerprint: "legacy")
    let orgA = claudeAccount(email: "same@example.com", orgID: "org-a", fingerprint: "a")
    let orgB = claudeAccount(email: "same@example.com", orgID: "org-b", fingerprint: "b")
    let newIdentity = ClaudeAccountIdentity(email: "same@example.com", organizationId: "org-c")!

    #expect(AccountResolution.storedClaudeMatch(identity: newIdentity, fingerprint: nil, accounts: [legacy])?.id == legacy.id)
    #expect(AccountResolution.storedClaudeMatch(identity: newIdentity, fingerprint: nil, accounts: [legacy, orgA, orgB]) == nil)
    #expect(AccountResolution.storedClaudeMatch(identity: newIdentity, fingerprint: "legacy", accounts: [legacy, orgA, orgB])?.id == legacy.id)
}

private func claudeAccount(email: String, orgID: String?, fingerprint: String) -> ClaudeStoredAccount {
    let id = UUID()
    return ClaudeStoredAccount(
        id: id, label: email, email: email, subscriptionType: "max", authMethod: "claude.ai",
        orgId: orgID, orgName: nil, createdAt: .distantPast, updatedAt: .distantPast,
        lastValidatedAt: nil, status: .ok, statusMessage: nil, authFingerprint: fingerprint,
        keychainAccount: "claude.\(id.uuidString)"
    )
}
