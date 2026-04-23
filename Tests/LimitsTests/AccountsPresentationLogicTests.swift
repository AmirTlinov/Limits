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
