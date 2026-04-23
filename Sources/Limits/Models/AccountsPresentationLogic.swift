import Foundation

enum AccountsDetailDestination: Equatable {
    case currentCodexCLI
    case currentClaudeCode
    case codexAccount(UUID)
    case claudeAccount(UUID)
}

enum AccountsPresentationLogic {
    static let storedRowsScrollThreshold = 4

    static func shouldShowCurrentClaude(
        source: AppModel.CurrentClaudeState.Source,
        storedClaudeCount: Int
    ) -> Bool {
        switch source {
        case .stored, .external, .loggedOut, .unreadable:
            return true
        case .notInstalled:
            return storedClaudeCount > 0
        }
    }

    static func needsStoredAccountsScroll(
        storedCodexCount: Int,
        storedClaudeCount: Int,
        threshold: Int = storedRowsScrollThreshold
    ) -> Bool {
        storedCodexCount + storedClaudeCount > threshold
    }

    static func detailDestination(
        selectionRaw: String,
        codexAccountIDs: Set<UUID>,
        claudeAccountIDs: Set<UUID>
    ) -> AccountsDetailDestination {
        if selectionRaw == "current-claude" {
            return .currentClaudeCode
        }

        if selectionRaw.hasPrefix("account:") {
            let rawID = String(selectionRaw.dropFirst("account:".count))
            if let id = UUID(uuidString: rawID), codexAccountIDs.contains(id) {
                return .codexAccount(id)
            }
            return .currentCodexCLI
        }

        if selectionRaw.hasPrefix("claude-account:") {
            let rawID = String(selectionRaw.dropFirst("claude-account:".count))
            if let id = UUID(uuidString: rawID), claudeAccountIDs.contains(id) {
                return .claudeAccount(id)
            }
            return .currentClaudeCode
        }

        return .currentCodexCLI
    }
}
