import Foundation
import LimitsShared

@frozen public enum ProviderKind: String, Codable, Hashable, Sendable, CaseIterable {
    case codex
    case claude
}

public struct CodexAccountIdentity: Codable, Hashable, Sendable {
    public let accountId: String

    public init?(_ accountId: String?) {
        guard let accountId = accountId?.trimmingCharacters(in: .whitespacesAndNewlines), !accountId.isEmpty else {
            return nil
        }
        self.accountId = accountId
    }
}

public struct ClaudeAccountIdentity: Codable, Hashable, Sendable {
    public let normalizedEmail: String
    public let organizationId: String?

    public init?(email: String?, organizationId: String?) {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
            return nil
        }
        normalizedEmail = email.lowercased()
        self.organizationId = organizationId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

@frozen public enum AccountStatus: String, Codable, Hashable, Sendable {
    case unknown
    case ok
    case needsReauth
    case limitReached
    case validationFailed
}

public struct RateLimitWindowSnapshot: Codable, Hashable, Sendable {
    public let resetsAt: Int64?
    public let usedPercent: Int
    public let windowDurationMins: Int64?

    public init(resetsAt: Int64?, usedPercent: Int, windowDurationMins: Int64?) {
        self.resetsAt = resetsAt
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
    }
}

public struct CreditsSnapshot: Codable, Hashable, Sendable {
    public let balance: String?
    public let hasCredits: Bool
    public let unlimited: Bool

    public init(balance: String?, hasCredits: Bool, unlimited: Bool) {
        self.balance = balance
        self.hasCredits = hasCredits
        self.unlimited = unlimited
    }
}

public struct SpendControlLimitSnapshot: Codable, Hashable, Sendable {
    public let limit: String
    public let remainingPercent: Int
    public let resetsAt: Int64
    public let used: String

    public init(limit: String, remainingPercent: Int, resetsAt: Int64, used: String) {
        self.limit = limit
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.used = used
    }
}

public struct RateLimitSnapshotModel: Codable, Hashable, Sendable {
    public let credits: CreditsSnapshot?
    public let limitId: String?
    public let limitName: String?
    public let planType: String?
    public let primary: RateLimitWindowSnapshot?
    public let rateLimitReachedType: String?
    public let secondary: RateLimitWindowSnapshot?
    public let spendControlReached: Bool?
    public let individualLimit: SpendControlLimitSnapshot?

    public init(
        credits: CreditsSnapshot?,
        limitId: String?,
        limitName: String?,
        planType: String?,
        primary: RateLimitWindowSnapshot?,
        rateLimitReachedType: String?,
        secondary: RateLimitWindowSnapshot?,
        spendControlReached: Bool? = nil,
        individualLimit: SpendControlLimitSnapshot? = nil
    ) {
        self.credits = credits
        self.limitId = limitId
        self.limitName = limitName
        self.planType = planType
        self.primary = primary
        self.rateLimitReachedType = rateLimitReachedType
        self.secondary = secondary
        self.spendControlReached = spendControlReached
        self.individualLimit = individualLimit
    }

    public var isReached: Bool {
        if spendControlReached == true {
            return true
        }
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

public struct ChatGPTSubscriptionPeriod: Codable, Hashable, Sendable {
    public let activeStart: Date?
    public let activeUntil: Date?
    public let lastCheckedAt: Date?

    public init(activeStart: Date?, activeUntil: Date?, lastCheckedAt: Date?) {
        self.activeStart = activeStart
        self.activeUntil = activeUntil
        self.lastCheckedAt = lastCheckedAt
    }
}

public struct StoredAccount: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var label: String
    public var email: String
    public var accountId: String?
    public var planType: String
    public let createdAt: Date
    public var updatedAt: Date
    public var lastValidatedAt: Date?
    public var status: AccountStatus
    public var statusMessage: String?
    public var authFingerprint: String
    public var keychainAccount: String
    public var subscriptionPeriod: ChatGPTSubscriptionPeriod?

    public init(
        id: UUID,
        label: String,
        email: String,
        accountId: String?,
        planType: String,
        createdAt: Date,
        updatedAt: Date,
        lastValidatedAt: Date?,
        status: AccountStatus,
        statusMessage: String?,
        authFingerprint: String,
        keychainAccount: String,
        subscriptionPeriod: ChatGPTSubscriptionPeriod? = nil
    ) {
        self.id = id
        self.label = label
        self.email = email
        self.accountId = accountId
        self.planType = planType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastValidatedAt = lastValidatedAt
        self.status = status
        self.statusMessage = statusMessage
        self.authFingerprint = authFingerprint
        self.keychainAccount = keychainAccount
        self.subscriptionPeriod = subscriptionPeriod
    }

    public var stableIdentity: CodexAccountIdentity? {
        CodexAccountIdentity(accountId)
    }

    public var shortStatusText: String {
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

public struct RetiredCredential: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let provider: ProviderKind
    public let sourceRecordID: UUID
    public let keychainAccount: String
    public let stableIdentity: String?
    public let retiredAt: Date
    public let purgeAfter: Date

    public init(id: UUID, provider: ProviderKind, sourceRecordID: UUID, keychainAccount: String, stableIdentity: String?, retiredAt: Date, purgeAfter: Date) {
        self.id = id
        self.provider = provider
        self.sourceRecordID = sourceRecordID
        self.keychainAccount = keychainAccount
        self.stableIdentity = stableIdentity
        self.retiredAt = retiredAt
        self.purgeAfter = purgeAfter
    }
}

public struct PendingAccountCleanup: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let provider: ProviderKind
    public let sourceRecordID: UUID
    public let keychainAccount: String
    public let codexAccountID: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        provider: ProviderKind,
        sourceRecordID: UUID,
        keychainAccount: String,
        codexAccountID: String?,
        createdAt: Date
    ) {
        self.id = id
        self.provider = provider
        self.sourceRecordID = sourceRecordID
        self.keychainAccount = keychainAccount
        self.codexAccountID = codexAccountID
        self.createdAt = createdAt
    }
}

public struct PersistedStateV5: Codable, Sendable {
    public static let currentSchemaVersion = 5

    public var schemaVersion: Int
    public var revision: UInt64
    public var accounts: [StoredAccount]
    public var claudeAccounts: [ClaudeStoredAccount]
    public var retiredCredentials: [RetiredCredential]
    public var pendingAccountCleanups: [PendingAccountCleanup]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        revision: UInt64 = 0,
        accounts: [StoredAccount],
        claudeAccounts: [ClaudeStoredAccount] = [],
        retiredCredentials: [RetiredCredential] = [],
        pendingAccountCleanups: [PendingAccountCleanup] = []
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.accounts = accounts
        self.claudeAccounts = claudeAccounts
        self.retiredCredentials = retiredCredentials
        self.pendingAccountCleanups = pendingAccountCleanups
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case revision
        case accounts
        case claudeAccounts
        case retiredCredentials
        case pendingAccountCleanups
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        revision = try container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        accounts = try container.decodeIfPresent([StoredAccount].self, forKey: .accounts) ?? []
        claudeAccounts = try container.decodeIfPresent([ClaudeStoredAccount].self, forKey: .claudeAccounts) ?? []
        retiredCredentials = try container.decodeIfPresent([RetiredCredential].self, forKey: .retiredCredentials) ?? []
        pendingAccountCleanups = try container.decodeIfPresent(
            [PendingAccountCleanup].self,
            forKey: .pendingAccountCleanups
        ) ?? []
    }
}

public struct AuthIdentity: Hashable, Sendable {
    public let authMode: String?
    public let accountId: String?
    public let email: String?

    public init(authMode: String?, accountId: String?, email: String?) {
        self.authMode = authMode
        self.accountId = accountId
        self.email = email
    }

    public var stableIdentity: CodexAccountIdentity? {
        CodexAccountIdentity(accountId)
    }
}

public struct AccountValidationResult: Sendable {
    public let authData: Data
    public let authFingerprint: String
    public let identity: AuthIdentity
    public let email: String
    public let planType: String
    public let rateLimit: RateLimitSnapshotModel?
    public let rateLimitsByLimitId: [String: RateLimitSnapshotModel]?
    public let rateLimitError: String?
    public let didRequestRateLimits: Bool
    public let accountUsage: CodexAccountUsageSnapshot?
    public let accountUsageError: String?
    public let didRequestAccountUsage: Bool
    public let threadUsageEvidence: CodexThreadUsageEvidence?
    public let subscriptionPeriod: ChatGPTSubscriptionPeriod?

    public init(
        authData: Data,
        authFingerprint: String,
        identity: AuthIdentity,
        email: String,
        planType: String,
        rateLimit: RateLimitSnapshotModel?,
        rateLimitsByLimitId: [String: RateLimitSnapshotModel]?,
        rateLimitError: String? = nil,
        didRequestRateLimits: Bool = true,
        accountUsage: CodexAccountUsageSnapshot? = nil,
        accountUsageError: String? = nil,
        didRequestAccountUsage: Bool = true,
        threadUsageEvidence: CodexThreadUsageEvidence? = nil,
        subscriptionPeriod: ChatGPTSubscriptionPeriod? = nil
    ) {
        self.authData = authData
        self.authFingerprint = authFingerprint
        self.identity = identity
        self.email = email
        self.planType = planType
        self.rateLimit = rateLimit
        self.rateLimitsByLimitId = rateLimitsByLimitId
        self.rateLimitError = rateLimitError
        self.didRequestRateLimits = didRequestRateLimits
        self.accountUsage = accountUsage
        self.accountUsageError = accountUsageError
        self.didRequestAccountUsage = didRequestAccountUsage
        self.threadUsageEvidence = threadUsageEvidence
        self.subscriptionPeriod = subscriptionPeriod
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
