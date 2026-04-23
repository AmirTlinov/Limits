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
