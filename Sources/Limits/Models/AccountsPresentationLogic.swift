import Foundation

enum AccountsDetailDestination: Equatable {
    case currentCodexCLI
    case currentClaudeCode
    case codexAccount(UUID)
    case claudeAccount(UUID)
}

enum AccountsSidebarFilter: String, CaseIterable {
    case all
    case codex
    case claude
}

enum TrayStatusProvider: Equatable {
    case codex
    case claude

    var displayTitle: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        }
    }
}

extension AccountsSidebarFilter {
    static let providerFilterStorageKey = "limits.tray.provider.filter"

    var includesCodex: Bool {
        switch self {
        case .all, .codex:
            return true
        case .claude:
            return false
        }
    }

    var includesClaude: Bool {
        switch self {
        case .all, .claude:
            return true
        case .codex:
            return false
        }
    }

    var trayStatusProvider: TrayStatusProvider {
        switch self {
        case .claude:
            return .claude
        case .all, .codex:
            return .codex
        }
    }
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

    static func isVisible(
        destination: AccountsDetailDestination,
        filter: AccountsSidebarFilter
    ) -> Bool {
        switch filter {
        case .all:
            return true
        case .codex:
            switch destination {
            case .currentCodexCLI, .codexAccount:
                return true
            case .currentClaudeCode, .claudeAccount:
                return false
            }
        case .claude:
            switch destination {
            case .currentClaudeCode, .claudeAccount:
                return true
            case .currentCodexCLI, .codexAccount:
                return false
            }
        }
    }

    static func defaultDestination(for filter: AccountsSidebarFilter) -> AccountsDetailDestination {
        switch filter {
        case .all, .codex:
            return .currentCodexCLI
        case .claude:
            return .currentClaudeCode
        }
    }
}
