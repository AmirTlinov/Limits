import Foundation

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
    var authFingerprint: String
    var keychainAccount: String

    var shortStatusText: String {
        switch status {
        case .unknown:
            return "Unknown"
        case .ok:
            return "OK"
        case .needsReauth:
            return "Reauth"
        case .limitReached:
            return "Limited"
        case .validationFailed:
            return "Failed"
        }
    }
}

struct PersistedState: Codable {
    var accounts: [StoredAccount]
}

struct AuthIdentity: Hashable {
    let authMode: String?
    let accountId: String?
}

struct AccountValidationResult {
    let authData: Data
    let authFingerprint: String
    let identity: AuthIdentity
    let email: String
    let planType: String
    let rateLimit: RateLimitSnapshotModel?
}

