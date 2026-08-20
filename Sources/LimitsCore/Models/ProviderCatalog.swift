import Foundation
import LimitsShared

@frozen public enum CodexSessionSource: Equatable, Sendable {
    case missing
    case stored(UUID)
    case external(String?)
    case unreadable
}

@frozen public enum ClaudeSessionSource: Equatable, Sendable {
    case notInstalled
    case loggedOut
    case stored(UUID)
    case external(String?)
    case unreadable

    public var hasLiveStableIdentity: Bool {
        switch self {
        case .stored, .external:
            return true
        case .notInstalled, .loggedOut, .unreadable:
            return false
        }
    }
}

public struct ProviderCatalogSnapshot: Equatable, Sendable {
    public let providers: [ProviderKind]
    public let savedClaudeCount: Int
    public let hasLiveClaudeIdentity: Bool

    public init(savedClaudeCount: Int, claudeSource: ClaudeSessionSource) {
        self.savedClaudeCount = savedClaudeCount
        hasLiveClaudeIdentity = claudeSource.hasLiveStableIdentity
        providers = savedClaudeCount > 0 || hasLiveClaudeIdentity ? [.codex, .claude] : [.codex]
    }

    public func contains(_ provider: ProviderKind) -> Bool {
        providers.contains(provider)
    }

    public var filterOptions: [AccountsSidebarFilter] {
        contains(.claude) ? [.all, .codex, .claude] : [.all, .codex]
    }

    public var trayProviders: [TrayStatusProvider] {
        providers.map { $0 == .codex ? .codex : .claude }
    }

    public var widgetProviderIDs: [LimitsWidgetProviderID] {
        providers.map { $0 == .codex ? .codex : .claude }
    }

    public func normalized(_ filter: AccountsSidebarFilter) -> AccountsSidebarFilter {
        if filter == .claude, !contains(.claude) {
            return .codex
        }
        return filter
    }
}
