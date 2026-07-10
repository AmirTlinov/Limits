import Foundation

struct ClaudeStoredAccount: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var label: String
    var email: String
    var subscriptionType: String
    var authMethod: String?
    var orgId: String?
    var orgName: String?
    let createdAt: Date
    var updatedAt: Date
    var lastValidatedAt: Date?
    var status: AccountStatus
    var statusMessage: String?
    var authFingerprint: String
    var keychainAccount: String

    var stableIdentity: ClaudeAccountIdentity? {
        ClaudeAccountIdentity(email: email, organizationId: orgId)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case email
        case subscriptionType
        case authMethod
        case orgId
        case orgName
        case createdAt
        case updatedAt
        case lastValidatedAt
        case status
        case statusMessage
        case authFingerprint
        case keychainAccount
    }

    init(
        id: UUID,
        label: String,
        email: String,
        subscriptionType: String,
        authMethod: String?,
        orgId: String? = nil,
        orgName: String?,
        createdAt: Date,
        updatedAt: Date,
        lastValidatedAt: Date?,
        status: AccountStatus,
        statusMessage: String?,
        authFingerprint: String,
        keychainAccount: String
    ) {
        self.id = id
        self.label = label
        self.email = email
        self.subscriptionType = subscriptionType
        self.authMethod = authMethod
        self.orgId = orgId
        self.orgName = orgName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastValidatedAt = lastValidatedAt
        self.status = status
        self.statusMessage = statusMessage
        self.authFingerprint = authFingerprint
        self.keychainAccount = keychainAccount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        email = try container.decode(String.self, forKey: .email)
        subscriptionType = try container.decode(String.self, forKey: .subscriptionType)
        authMethod = try container.decodeIfPresent(String.self, forKey: .authMethod)
        orgId = try container.decodeIfPresent(String.self, forKey: .orgId)
        orgName = try container.decodeIfPresent(String.self, forKey: .orgName)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        lastValidatedAt = try container.decodeIfPresent(Date.self, forKey: .lastValidatedAt)
        status = try container.decode(AccountStatus.self, forKey: .status)
        statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
        authFingerprint = try container.decode(String.self, forKey: .authFingerprint)
        keychainAccount = try container.decode(String.self, forKey: .keychainAccount)
    }

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
