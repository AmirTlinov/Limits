import Foundation

@frozen public enum ReauthenticationTarget: Equatable, Sendable {
    case requestedAccount(UUID)
    case existingAccount(UUID)
    case newAccount
}

public enum AccountResolution {
    public static func storedCodexMatch(
        identity: AuthIdentity,
        fingerprint: String,
        accounts: [StoredAccount]
    ) -> StoredAccount? {
        if let exact = accounts.first(where: { $0.authFingerprint == fingerprint }) {
            return exact
        }
        guard let stableIdentity = identity.stableIdentity else { return nil }
        let stableMatches = accounts.filter { $0.stableIdentity == stableIdentity }
        return stableMatches.count == 1 ? stableMatches[0] : nil
    }

    public static func importedCodexAccount(
        fingerprint: String?,
        accountId: String?,
        email: String?,
        accounts: [StoredAccount]
    ) -> StoredAccount? {
        if let fingerprint,
           let matched = accounts.first(where: { $0.authFingerprint == fingerprint }) {
            return matched
        }
        if let accountId {
            let matches = accounts.filter { $0.accountId == accountId }
            if matches.count == 1 { return matches[0] }
        }
        if let email {
            let matches = accounts.filter { $0.email.caseInsensitiveCompare(email) == .orderedSame }
            if matches.count == 1 { return matches[0] }
        }
        return nil
    }

    public static func storedClaudeMatch(
        identity: ClaudeAccountIdentity,
        fingerprint: String?,
        accounts: [ClaudeStoredAccount]
    ) -> ClaudeStoredAccount? {
        let stableMatches = accounts.filter { $0.stableIdentity == identity }
        if stableMatches.count == 1 { return stableMatches[0] }

        if let fingerprint {
            let credentialMatches = accounts.filter {
                $0.authFingerprint == fingerprint
                    && ($0.orgId == nil || $0.stableIdentity == identity)
            }
            if credentialMatches.count == 1 { return credentialMatches[0] }
        }

        let emailMatches = accounts.filter {
            $0.email.caseInsensitiveCompare(identity.normalizedEmail) == .orderedSame
        }
        let legacyMatches = emailMatches.filter {
            $0.orgId == nil
        }
        return legacyMatches.count == 1 && emailMatches.count == 1 ? legacyMatches[0] : nil
    }

    public static func reauthenticationTarget(
        requested: StoredAccount,
        result: AccountValidationResult,
        accounts: [StoredAccount]
    ) -> ReauthenticationTarget {
        if result.identity.stableIdentity == requested.stableIdentity,
           result.identity.stableIdentity != nil {
            return .requestedAccount(requested.id)
        }
        if let exact = accounts.first(where: { $0.authFingerprint == result.authFingerprint }) {
            return exact.id == requested.id ? .requestedAccount(requested.id) : .existingAccount(exact.id)
        }
        if let identity = result.identity.stableIdentity {
            let matches = accounts.filter { $0.stableIdentity == identity }
            if matches.count == 1, let match = matches.first {
                return match.id == requested.id ? .requestedAccount(requested.id) : .existingAccount(match.id)
            }
        }
        return .newAccount
    }

    public static func validationStatus(forErrorMessage message: String) -> AccountStatus {
        let normalized = message.lowercased()
        if normalized.contains("unauthorized") || normalized.contains("401") || normalized.contains("auth") || normalized.contains("login") {
            return .needsReauth
        }
        if normalized.contains("token_expired") || normalized.contains("token_invalidated") || normalized.contains("refresh token") || normalized.contains("signing in again") {
            return .needsReauth
        }
        return .validationFailed
    }
}
