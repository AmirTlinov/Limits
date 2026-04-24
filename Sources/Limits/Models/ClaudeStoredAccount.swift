import Foundation

struct ClaudeStoredAccount: Identifiable, Codable, Hashable {
    let id: UUID
    var label: String
    var email: String
    var subscriptionType: String
    var authMethod: String?
    var orgName: String?
    let createdAt: Date
    var updatedAt: Date
    var lastValidatedAt: Date?
    var status: AccountStatus
    var statusMessage: String?
    var authFingerprint: String
    var keychainAccount: String

    var shortStatusText: String {
        switch status {
        case .unknown:
            return L10n.tr("account.unknown")
        case .ok:
            return L10n.tr("account.ready")
        case .needsReauth:
            return L10n.tr("account.needs_login")
        case .limitReached:
            return L10n.tr("account.limit")
        case .validationFailed:
            return L10n.tr("account.error")
        }
    }
}
