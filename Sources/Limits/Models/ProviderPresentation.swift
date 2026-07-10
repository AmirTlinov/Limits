import Foundation

enum ProviderTone: Hashable {
    case codex
    case claude
    case success
    case warning
    case danger
    case secondary
}

struct ProviderBadgePresentation: Hashable {
    let text: String
    let tone: ProviderTone
}

enum ProviderPresentation {
    static func codexBadge(source: AppModel.CurrentCLIState.Source) -> ProviderBadgePresentation {
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

    static func trayCodexBadge(source: AppModel.CurrentCLIState.Source) -> ProviderBadgePresentation {
        switch source {
        case .stored, .external:
            ProviderBadgePresentation(text: L10n.tr("account.current"), tone: .codex)
        case .missing:
            ProviderBadgePresentation(text: L10n.tr("account.no_login"), tone: .secondary)
        case .unreadable:
            ProviderBadgePresentation(text: L10n.tr("account.error"), tone: .danger)
        }
    }

    static func claudeBadge(source: AppModel.CurrentClaudeState.Source) -> ProviderBadgePresentation {
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

    static func trayClaudeBadge(source: AppModel.CurrentClaudeState.Source) -> ProviderBadgePresentation {
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

    static func accountBadge(
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

    static func currentCodexCountsAsAccount(_ source: AppModel.CurrentCLIState.Source) -> Bool {
        switch source {
        case .stored, .external:
            return true
        case .missing, .unreadable:
            return false
        }
    }

    static func currentClaudeCountsAsAccount(_ source: AppModel.CurrentClaudeState.Source) -> Bool {
        switch source {
        case .stored, .external:
            return true
        case .loggedOut, .notInstalled, .unreadable:
            return false
        }
    }

    static func statusTone(
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
