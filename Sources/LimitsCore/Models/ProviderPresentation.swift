import Foundation
import LimitsShared

@frozen public enum ProviderTone: Hashable, Sendable {
    case codex
    case claude
    case success
    case warning
    case danger
    case secondary
}

public struct ProviderBadgePresentation: Hashable, Sendable {
    public let text: String
    public let tone: ProviderTone

    public init(text: String, tone: ProviderTone) {
        self.text = text
        self.tone = tone
    }
}

public enum ProviderPresentation {
    public static func codexBadge(source: CodexSessionSource) -> ProviderBadgePresentation {
        switch source {
        case .stored:
            ProviderBadgePresentation(text: L10n.tr("account.active"), tone: .codex)
        case .external:
            ProviderBadgePresentation(text: L10n.tr("account.current") + " CLI", tone: .secondary)
        case .missing:
            ProviderBadgePresentation(text: L10n.tr("account.no_login"), tone: .secondary)
        case .unreadable:
            ProviderBadgePresentation(text: L10n.tr("account.error"), tone: .danger)
        }
    }

    public static func trayCodexBadge(source: CodexSessionSource) -> ProviderBadgePresentation {
        switch source {
        case .stored, .external:
            ProviderBadgePresentation(text: L10n.tr("account.current"), tone: .codex)
        case .missing:
            ProviderBadgePresentation(text: L10n.tr("account.no_login"), tone: .secondary)
        case .unreadable:
            ProviderBadgePresentation(text: L10n.tr("account.error"), tone: .danger)
        }
    }

    public static func claudeBadge(source: ClaudeSessionSource) -> ProviderBadgePresentation {
        switch source {
        case .stored:
            ProviderBadgePresentation(text: L10n.tr("account.current"), tone: .claude)
        case .external:
            ProviderBadgePresentation(text: L10n.tr("account.external"), tone: .claude)
        case .loggedOut:
            ProviderBadgePresentation(text: L10n.tr("account.no_login"), tone: .danger)
        case .notInstalled:
            ProviderBadgePresentation(text: L10n.tr("account.not_installed"), tone: .secondary)
        case .unreadable:
            ProviderBadgePresentation(text: L10n.tr("account.error"), tone: .danger)
        }
    }

    public static func trayClaudeBadge(source: ClaudeSessionSource) -> ProviderBadgePresentation {
        switch source {
        case .stored, .external:
            ProviderBadgePresentation(text: L10n.tr("account.current"), tone: .claude)
        case .loggedOut:
            ProviderBadgePresentation(text: L10n.tr("account.no_login"), tone: .danger)
        case .notInstalled:
            ProviderBadgePresentation(text: L10n.tr("account.no_cli"), tone: .secondary)
        case .unreadable:
            ProviderBadgePresentation(text: L10n.tr("account.error"), tone: .danger)
        }
    }

    public static func accountBadge(
        status: AccountStatus,
        isCurrent: Bool,
        provider: TrayStatusProvider
    ) -> ProviderBadgePresentation {
        if isCurrent {
            return ProviderBadgePresentation(
                text: L10n.tr("account.current"),
                tone: provider == .codex ? .codex : .claude
            )
        }

        return switch status {
        case .ok:
            ProviderBadgePresentation(text: L10n.tr("account.ready"), tone: .success)
        case .limitReached:
            ProviderBadgePresentation(text: L10n.tr("account.limit"), tone: .warning)
        case .needsReauth:
            ProviderBadgePresentation(text: L10n.tr("account.needs_login"), tone: .danger)
        case .validationFailed:
            ProviderBadgePresentation(text: L10n.tr("account.error"), tone: .danger)
        case .unknown:
            ProviderBadgePresentation(text: L10n.tr("account.unknown"), tone: .secondary)
        }
    }

    public static func currentCodexCountsAsAccount(_ source: CodexSessionSource) -> Bool {
        switch source {
        case .stored, .external:
            return true
        case .missing, .unreadable:
            return false
        }
    }

    public static func currentClaudeCountsAsAccount(_ source: ClaudeSessionSource) -> Bool {
        switch source {
        case .stored, .external:
            return true
        case .loggedOut, .notInstalled, .unreadable:
            return false
        }
    }

    public static func statusTone(
        status: AccountStatus,
        isCurrent: Bool,
        provider: TrayStatusProvider
    ) -> ProviderTone {
        if isCurrent {
            return provider == .codex ? .codex : .claude
        }

        switch status {
        case .ok:
            return .success
        case .limitReached:
            return .warning
        case .needsReauth, .validationFailed:
            return .danger
        case .unknown:
            return .secondary
        }
    }
}
