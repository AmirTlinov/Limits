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
            return "Неизвестно"
        case .ok:
            return "Готов"
        case .needsReauth:
            return "Нужен вход"
        case .limitReached:
            return "Лимит"
        case .validationFailed:
            return "Ошибка"
        }
    }
}
