import Foundation

enum ProviderKind: String, Codable, Hashable, Sendable, CaseIterable {
    case codex
    case claude
}

struct CodexAccountIdentity: Codable, Hashable, Sendable {
    let accountId: String

    init?(_ accountId: String?) {
        guard let accountId = accountId?.trimmingCharacters(in: .whitespacesAndNewlines), !accountId.isEmpty else {
            return nil
        }
        self.accountId = accountId
    }
}

struct ClaudeAccountIdentity: Codable, Hashable, Sendable {
    let normalizedEmail: String
    let organizationId: String?

    init?(email: String?, organizationId: String?) {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
            return nil
        }
        normalizedEmail = email.lowercased()
        self.organizationId = organizationId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

enum AccountStatus: String, Codable, Hashable {
    case unknown
    case ok
    case needsReauth
    case limitReached
    case validationFailed
}

struct RateLimitWindowSnapshot: Codable, Hashable {
    let resetsAt: Int64?
    let usedPercent: Int
    let windowDurationMins: Int64?
}

struct CreditsSnapshot: Codable, Hashable {
    let balance: String?
    let hasCredits: Bool
    let unlimited: Bool
}

struct RateLimitSnapshotModel: Codable, Hashable {
    let credits: CreditsSnapshot?
    let limitId: String?
    let limitName: String?
    let planType: String?
    let primary: RateLimitWindowSnapshot?
    let rateLimitReachedType: String?
    let secondary: RateLimitWindowSnapshot?

    var isReached: Bool {
        if rateLimitReachedType != nil {
            return true
        }
        if let primary, primary.usedPercent >= 100 {
            return true
        }
        if let secondary, secondary.usedPercent >= 100 {
            return true
        }
        return false
    }
}

struct StoredAccount: Identifiable, Codable, Hashable {
    let id: UUID
    var label: String
    var email: String
    var accountId: String?
    var planType: String
    let createdAt: Date
    var updatedAt: Date
    var lastValidatedAt: Date?
    var status: AccountStatus
    var statusMessage: String?
    var lastRateLimit: RateLimitSnapshotModel?
    var lastRateLimitsByLimitId: [String: RateLimitSnapshotModel]?
    var authFingerprint: String
    var keychainAccount: String

    var stableIdentity: CodexAccountIdentity? {
        CodexAccountIdentity(accountId)
    }

    var shortStatusText: String {
        switch status {
        case .unknown:
            return L10n.tr("account.unknown")
        case .ok:
            return "OK"
        case .needsReauth:
            return L10n.tr("account.needs_login")
        case .limitReached:
            return L10n.tr("account.limit_reached")
        case .validationFailed:
            return L10n.tr("account.error")
        }
    }
}

struct RetiredCredential: Codable, Hashable, Identifiable {
    let id: UUID
    let provider: ProviderKind
    let sourceRecordID: UUID
    let keychainAccount: String
    let stableIdentity: String?
    let retiredAt: Date
    let purgeAfter: Date
}

struct PersistedState: Codable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var accounts: [StoredAccount]
    var claudeAccounts: [ClaudeStoredAccount]
    var retiredCredentials: [RetiredCredential]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        accounts: [StoredAccount],
        claudeAccounts: [ClaudeStoredAccount] = [],
        retiredCredentials: [RetiredCredential] = []
    ) {
        self.schemaVersion = schemaVersion
        self.accounts = accounts
        self.claudeAccounts = claudeAccounts
        self.retiredCredentials = retiredCredentials
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case accounts
        case claudeAccounts
        case retiredCredentials
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        accounts = try container.decodeIfPresent([StoredAccount].self, forKey: .accounts) ?? []
        claudeAccounts = try container.decodeIfPresent([ClaudeStoredAccount].self, forKey: .claudeAccounts) ?? []
        retiredCredentials = try container.decodeIfPresent([RetiredCredential].self, forKey: .retiredCredentials) ?? []
    }
}

struct AuthIdentity: Hashable {
    let authMode: String?
    let accountId: String?
    let email: String?
}

struct AccountValidationResult {
    let authData: Data
    let authFingerprint: String
    let identity: AuthIdentity
    let email: String
    let planType: String
    let rateLimit: RateLimitSnapshotModel?
    let rateLimitsByLimitId: [String: RateLimitSnapshotModel]?
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
