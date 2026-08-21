import Foundation
import LimitsShared

@frozen public enum CodexAccountIssueAction: Hashable, Sendable {
    case automaticRetry
    case reauthenticate
}

public struct CodexAccountIssuePresentation: Hashable, Sendable {
    public let title: String
    public let message: String
    public let recommendedAction: CodexAccountIssueAction

    public init(title: String, message: String, recommendedAction: CodexAccountIssueAction) {
        self.title = title
        self.message = message
        self.recommendedAction = recommendedAction
    }
}

public enum CodexAccountIssuePresentationPolicy {
    public static func presentation(for account: StoredAccount) -> CodexAccountIssuePresentation? {
        let limitsIssue = account.limitsIssue
            ?? CodexAccountValidationPolicy.legacyLimitsIssue(from: account.statusMessage)

        switch limitsIssue {
        case .authorizationExpired:
            return CodexAccountIssuePresentation(
                title: L10n.tr("limits.authorization_expired.title"),
                message: L10n.tr("limits.authorization_expired.message"),
                recommendedAction: .reauthenticate
            )
        case .temporarilyUnavailable:
            return CodexAccountIssuePresentation(
                title: L10n.tr("limits.unavailable.title"),
                message: L10n.tr("limits.unavailable.message"),
                recommendedAction: .automaticRetry
            )
        case nil:
            break
        }

        switch account.status {
        case .needsReauth:
            return CodexAccountIssuePresentation(
                title: L10n.tr("limits.authorization_expired.title"),
                message: L10n.tr("limits.authorization_expired.message"),
                recommendedAction: .reauthenticate
            )
        case .validationFailed:
            return CodexAccountIssuePresentation(
                title: L10n.tr("account.validation_failed.title"),
                message: L10n.tr("account.validation_failed.message"),
                recommendedAction: .automaticRetry
            )
        case .unknown, .ok, .limitReached:
            return nil
        }
    }
}
