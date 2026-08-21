import Foundation

@frozen public enum AccountsDetailDestination: Equatable, Sendable {
    case codexOverview
    case currentClaudeCode
    case codexAccount(UUID)
    case claudeAccount(UUID)
}

@frozen public enum AccountsSidebarFilter: String, CaseIterable, Sendable {
    case all
    case codex
    case claude
}

@frozen public enum TrayStatusProvider: Equatable, Hashable, Sendable {
    case codex
    case claude

    public var displayTitle: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        }
    }
}

extension AccountsSidebarFilter {
    public static let providerFilterStorageKey = "limits.tray.provider.filter"

    public var includesCodex: Bool {
        switch self {
        case .all, .codex:
            return true
        case .claude:
            return false
        }
    }

    public var includesClaude: Bool {
        switch self {
        case .all, .claude:
            return true
        case .codex:
            return false
        }
    }

    public var trayStatusProvider: TrayStatusProvider {
        switch self {
        case .claude:
            return .claude
        case .all, .codex:
            return .codex
        }
    }
}

public enum AccountsPresentationLogic {
    public static let storedRowsScrollThreshold = 4

    public static func needsStoredAccountsScroll(
        storedCodexCount: Int,
        storedClaudeCount: Int,
        threshold: Int = storedRowsScrollThreshold
    ) -> Bool {
        storedCodexCount + storedClaudeCount > threshold
    }

    public static func detailDestination(
        selectionRaw: String,
        codexAccountIDs: Set<UUID>,
        claudeAccountIDs: Set<UUID>
    ) -> AccountsDetailDestination {
        if selectionRaw == "current-claude" {
            return .currentClaudeCode
        }

        if selectionRaw == "codex-overview" {
            return .codexOverview
        }

        if selectionRaw.hasPrefix("account:") {
            let rawID = String(selectionRaw.dropFirst("account:".count))
            if let id = UUID(uuidString: rawID), codexAccountIDs.contains(id) {
                return .codexAccount(id)
            }
            return .codexOverview
        }

        if selectionRaw.hasPrefix("claude-account:") {
            let rawID = String(selectionRaw.dropFirst("claude-account:".count))
            if let id = UUID(uuidString: rawID), claudeAccountIDs.contains(id) {
                return .claudeAccount(id)
            }
            return .currentClaudeCode
        }

        return .codexOverview
    }

    public static func isVisible(
        destination: AccountsDetailDestination,
        filter: AccountsSidebarFilter,
        catalog: ProviderCatalogSnapshot
    ) -> Bool {
        let isClaudeDestination: Bool = switch destination {
        case .currentClaudeCode, .claudeAccount: true
        case .codexOverview, .codexAccount: false
        }
        if isClaudeDestination, !catalog.contains(.claude) { return false }
        switch filter {
        case .all:
            return true
        case .codex:
            switch destination {
            case .codexOverview, .codexAccount:
                return true
            case .currentClaudeCode, .claudeAccount:
                return false
            }
        case .claude:
            switch destination {
            case .currentClaudeCode, .claudeAccount:
                return true
            case .codexOverview, .codexAccount:
                return false
            }
        }
    }

    public static func defaultDestination(
        for filter: AccountsSidebarFilter,
        catalog: ProviderCatalogSnapshot
    ) -> AccountsDetailDestination {
        switch catalog.normalized(filter) {
        case .all, .codex:
            return .codexOverview
        case .claude:
            return .currentClaudeCode
        }
    }
}
