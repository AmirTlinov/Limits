import Foundation
import LimitsShared

@frozen public enum AccountsRepositoryAccess: Equatable, Sendable {
    case readWrite
    case readOnlyRecovery(schemaVersion: Int)
}

public struct AccountsRepositorySnapshot: Sendable {
    public let state: PersistedStateV3
    public let access: AccountsRepositoryAccess

    public init(state: PersistedStateV3, access: AccountsRepositoryAccess) {
        self.state = state
        self.access = access
    }
}

public enum AccountsRepositoryError: LocalizedError, Equatable {
    case notOpened
    case readOnlyRecovery(schemaVersion: Int)
    case revisionConflict(expected: UInt64, actual: UInt64)
    case revisionExhausted
    case accountMissing(UUID)
    case credentialMissing(UUID)

    public var errorDescription: String? {
        switch self {
        case .notOpened:
            return L10n.tr("accounts.repository.not_opened")
        case .readOnlyRecovery(let schemaVersion):
            return L10n.tr("accounts.repository.read_only", schemaVersion)
        case .revisionConflict(let expected, let actual):
            return L10n.tr("accounts.repository.revision_conflict", String(expected), String(actual))
        case .revisionExhausted:
            return L10n.tr("accounts.repository.revision_exhausted")
        case .accountMissing:
            return L10n.tr("accounts.repository.account_missing")
        case .credentialMissing:
            return L10n.tr("accounts.repository.credential_missing")
        }
    }
}

@frozen public enum AccountsRepositoryCheckpoint: Equatable, Sendable {
    case afterReload
    case afterCredentialWrite
    case beforeStateWrite
    case afterStateWrite
    case beforeCredentialDelete
}

public actor AccountsRepository {
    public typealias FaultInjector = @Sendable (AccountsRepositoryCheckpoint) throws -> Void

    private let persistence: AccountsPersistence
    private let vault: KeychainAuthVault
    private let faultInjector: FaultInjector
    private var cachedSnapshot: AccountsRepositorySnapshot?

    public init(
        persistence: AccountsPersistence = AccountsPersistence(),
        vault: KeychainAuthVault = KeychainAuthVault(),
        faultInjector: @escaping FaultInjector = { _ in }
    ) {
        self.persistence = persistence
        self.vault = vault
        self.faultInjector = faultInjector
    }

    @discardableResult
    public func open(
        currentCodexFingerprint: String?,
        currentClaudeFingerprint: String?,
        now: Date = .now
    ) throws -> AccountsRepositorySnapshot {
        let snapshot = try persistence.withExclusiveLock {
            let originalData = try persistence.loadData()
            let source = try originalData.map { try JSONDecoder.limits.decode(PersistedStateV3.self, from: $0) }
                ?? PersistedStateV3(accounts: [])

            if source.schemaVersion > PersistedStateV3.currentSchemaVersion {
                return AccountsRepositorySnapshot(
                    state: source,
                    access: .readOnlyRecovery(schemaVersion: source.schemaVersion)
                )
            }

            let migration = PersistedStateMigrator.migrate(
                source,
                currentCodexFingerprint: currentCodexFingerprint,
                currentClaudeFingerprint: currentClaudeFingerprint,
                now: now
            )
            var state = migration.state
            if migration.receipt.didChange {
                if let originalData {
                    try persistence.backupBeforeV3Migration(originalData)
                }
                try advanceRevision(&state)
                try faultInjector(.beforeStateWrite)
                try persistence.save(state)
                try faultInjector(.afterStateWrite)
            }
            return AccountsRepositorySnapshot(state: state, access: .readWrite)
        }
        cachedSnapshot = snapshot
        return snapshot
    }

    public func snapshot() throws -> AccountsRepositorySnapshot {
        guard let cachedSnapshot else {
            throw AccountsRepositoryError.notOpened
        }
        return cachedSnapshot
    }

    @discardableResult
    public func reload() throws -> AccountsRepositorySnapshot {
        let snapshot = try persistence.withExclusiveLock {
            try loadCurrentStateLocked()
        }
        cachedSnapshot = snapshot
        return snapshot
    }

    public func credential(provider: ProviderKind, accountID: UUID) throws -> Data {
        let snapshot = try reload()
        let reference: String?
        switch provider {
        case .codex:
            reference = snapshot.state.accounts.first(where: { $0.id == accountID })?.keychainAccount
        case .claude:
            reference = snapshot.state.claudeAccounts.first(where: { $0.id == accountID })?.keychainAccount
        }
        guard let reference else {
            throw AccountsRepositoryError.credentialMissing(accountID)
        }
        return try vault.read(account: reference)
    }

    @discardableResult
    public func saveCodexAccount(
        _ account: StoredAccount,
        credential: Data,
        expectedRevision: UInt64? = nil,
        now: Date = .now
    ) throws -> AccountsRepositorySnapshot {
        try replaceCredential(
            provider: .codex,
            recordID: account.id,
            label: account.label,
            credential: credential,
            expectedRevision: expectedRevision,
            now: now
        ) { state, newReference in
            var stored = account
            stored.keychainAccount = newReference
            stored.authFingerprint = CodexAuthBlob.fingerprint(for: credential)
            if let index = state.accounts.firstIndex(where: { $0.id == account.id }) {
                state.accounts[index] = stored
            } else {
                state.accounts.append(stored)
            }
            state.accounts.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        }
    }

    @discardableResult
    public func saveClaudeAccount(
        _ account: ClaudeStoredAccount,
        credential: Data,
        expectedRevision: UInt64? = nil,
        now: Date = .now
    ) throws -> AccountsRepositorySnapshot {
        try replaceCredential(
            provider: .claude,
            recordID: account.id,
            label: account.label,
            credential: credential,
            expectedRevision: expectedRevision,
            now: now
        ) { state, newReference in
            var stored = account
            stored.keychainAccount = newReference
            stored.authFingerprint = CodexAuthBlob.fingerprint(for: credential)
            if let index = state.claudeAccounts.firstIndex(where: { $0.id == account.id }) {
                state.claudeAccounts[index] = stored
            } else {
                state.claudeAccounts.append(stored)
            }
            state.claudeAccounts.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        }
    }

    @discardableResult
    public func updateCodexAccount(
        _ account: StoredAccount,
        expectedRevision: UInt64? = nil
    ) throws -> AccountsRepositorySnapshot {
        try mutate(expectedRevision: expectedRevision) { state in
            guard let index = state.accounts.firstIndex(where: { $0.id == account.id }) else {
                throw AccountsRepositoryError.accountMissing(account.id)
            }
            var updated = account
            updated.keychainAccount = state.accounts[index].keychainAccount
            state.accounts[index] = updated
            state.accounts.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        }
    }

    @discardableResult
    public func updateClaudeAccount(
        _ account: ClaudeStoredAccount,
        expectedRevision: UInt64? = nil
    ) throws -> AccountsRepositorySnapshot {
        try mutate(expectedRevision: expectedRevision) { state in
            guard let index = state.claudeAccounts.firstIndex(where: { $0.id == account.id }) else {
                throw AccountsRepositoryError.accountMissing(account.id)
            }
            var updated = account
            updated.keychainAccount = state.claudeAccounts[index].keychainAccount
            state.claudeAccounts[index] = updated
            state.claudeAccounts.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        }
    }

    @discardableResult
    public func deleteAccount(
        provider: ProviderKind,
        accountID: UUID,
        expectedRevision: UInt64? = nil,
        now: Date = .now
    ) throws -> AccountsRepositorySnapshot {
        var retiredReference: String?
        var retiredID: UUID?
        let removed = try mutate(expectedRevision: expectedRevision) { state in
            switch provider {
            case .codex:
                guard let index = state.accounts.firstIndex(where: { $0.id == accountID }) else {
                    throw AccountsRepositoryError.accountMissing(accountID)
                }
                let account = state.accounts.remove(at: index)
                retiredReference = account.keychainAccount
                let retired = makeRetiredCredential(
                    provider: .codex,
                    recordID: account.id,
                    keychainAccount: account.keychainAccount,
                    stableIdentity: account.accountId.map { "codex:\($0)" },
                    purgeAfter: now,
                    now: now
                )
                retiredID = retired.id
                state.retiredCredentials.append(retired)
            case .claude:
                guard let index = state.claudeAccounts.firstIndex(where: { $0.id == accountID }) else {
                    throw AccountsRepositoryError.accountMissing(accountID)
                }
                let account = state.claudeAccounts.remove(at: index)
                retiredReference = account.keychainAccount
                let identity = account.stableIdentity.map { "claude:\($0.normalizedEmail)|\($0.organizationId ?? "-")" }
                let retired = makeRetiredCredential(
                    provider: .claude,
                    recordID: account.id,
                    keychainAccount: account.keychainAccount,
                    stableIdentity: identity,
                    purgeAfter: now,
                    now: now
                )
                retiredID = retired.id
                state.retiredCredentials.append(retired)
            }
        }

        guard let retiredReference, let retiredID else { return removed }
        do {
            try faultInjector(.beforeCredentialDelete)
            try vault.delete(account: retiredReference)
            return try mutate { state in
                state.retiredCredentials.removeAll { $0.id == retiredID }
            }
        } catch {
            return removed
        }
    }

    @discardableResult
    public func purgeRetiredCredentials(now: Date = .now) throws -> AccountsRepositorySnapshot {
        let snapshot = try reload()
        guard snapshot.access == .readWrite else { return snapshot }
        let active = Set(snapshot.state.accounts.map(\.keychainAccount) + snapshot.state.claudeAccounts.map(\.keychainAccount))
        let expired = snapshot.state.retiredCredentials.filter {
            $0.purgeAfter <= now && !active.contains($0.keychainAccount)
        }
        guard !expired.isEmpty else { return snapshot }

        var deleted = Set<UUID>()
        for retired in expired {
            do {
                try faultInjector(.beforeCredentialDelete)
                try vault.delete(account: retired.keychainAccount)
                deleted.insert(retired.id)
            } catch {
                continue
            }
        }
        guard !deleted.isEmpty else { return snapshot }
        return try mutate { state in
            state.retiredCredentials.removeAll { deleted.contains($0.id) }
        }
    }

    private func replaceCredential(
        provider: ProviderKind,
        recordID: UUID,
        label: String,
        credential: Data,
        expectedRevision: UInt64?,
        now: Date,
        update: (inout PersistedStateV3, String) throws -> Void
    ) throws -> AccountsRepositorySnapshot {
        let result = try persistence.withExclusiveLock {
            var snapshot = try loadCurrentStateLocked()
            try requireWritable(snapshot)
            try verifyRevision(expectedRevision, actual: snapshot.state.revision)
            try faultInjector(.afterReload)

            var state = snapshot.state
            let previousReference: String? = switch provider {
            case .codex:
                state.accounts.first(where: { $0.id == recordID })?.keychainAccount
            case .claude:
                state.claudeAccounts.first(where: { $0.id == recordID })?.keychainAccount
            }
            let newReference = "\(provider.rawValue).\(recordID.uuidString).\(UUID().uuidString)"
            try vault.save(credential, account: newReference, label: label)
            var stateCommitted = false
            do {
                try faultInjector(.afterCredentialWrite)
                try update(&state, newReference)
                if let previousReference, previousReference != newReference {
                    state.retiredCredentials.append(
                        makeRetiredCredential(
                            provider: provider,
                            recordID: recordID,
                            keychainAccount: previousReference,
                            stableIdentity: stableIdentity(provider: provider, recordID: recordID, state: state),
                            purgeAfter: now.addingTimeInterval(PersistedStateMigrator.retiredCredentialRetention),
                            now: now
                        )
                    )
                }
                state.schemaVersion = PersistedStateV3.currentSchemaVersion
                try advanceRevision(&state)
                try faultInjector(.beforeStateWrite)
                try persistence.save(state)
                stateCommitted = true
                try faultInjector(.afterStateWrite)
                snapshot = AccountsRepositorySnapshot(state: state, access: .readWrite)
                return snapshot
            } catch {
                if !stateCommitted {
                    try? vault.delete(account: newReference)
                }
                throw error
            }
        }
        cachedSnapshot = result
        return result
    }

    private func mutate(
        expectedRevision: UInt64? = nil,
        _ update: (inout PersistedStateV3) throws -> Void
    ) throws -> AccountsRepositorySnapshot {
        let result = try persistence.withExclusiveLock {
            let loaded = try loadCurrentStateLocked()
            try requireWritable(loaded)
            try verifyRevision(expectedRevision, actual: loaded.state.revision)
            try faultInjector(.afterReload)
            var state = loaded.state
            try update(&state)
            state.schemaVersion = PersistedStateV3.currentSchemaVersion
            try advanceRevision(&state)
            try faultInjector(.beforeStateWrite)
            try persistence.save(state)
            try faultInjector(.afterStateWrite)
            return AccountsRepositorySnapshot(state: state, access: .readWrite)
        }
        cachedSnapshot = result
        return result
    }

    private func loadCurrentStateLocked() throws -> AccountsRepositorySnapshot {
        let state = try persistence.load()
        if state.schemaVersion > PersistedStateV3.currentSchemaVersion {
            return AccountsRepositorySnapshot(
                state: state,
                access: .readOnlyRecovery(schemaVersion: state.schemaVersion)
            )
        }
        guard state.schemaVersion == PersistedStateV3.currentSchemaVersion else {
            throw AccountsRepositoryError.readOnlyRecovery(schemaVersion: state.schemaVersion)
        }
        return AccountsRepositorySnapshot(state: state, access: .readWrite)
    }

    private func requireWritable(_ snapshot: AccountsRepositorySnapshot) throws {
        if case .readOnlyRecovery(let version) = snapshot.access {
            throw AccountsRepositoryError.readOnlyRecovery(schemaVersion: version)
        }
    }

    private func verifyRevision(_ expected: UInt64?, actual: UInt64) throws {
        if let expected, expected != actual {
            throw AccountsRepositoryError.revisionConflict(expected: expected, actual: actual)
        }
    }

    private func advanceRevision(_ state: inout PersistedStateV3) throws {
        guard state.revision < UInt64.max else {
            throw AccountsRepositoryError.revisionExhausted
        }
        state.revision += 1
    }

    private func stableIdentity(provider: ProviderKind, recordID: UUID, state: PersistedStateV3) -> String? {
        switch provider {
        case .codex:
            return state.accounts.first(where: { $0.id == recordID })?.accountId.map { "codex:\($0)" }
        case .claude:
            return state.claudeAccounts.first(where: { $0.id == recordID })?.stableIdentity.map {
                "claude:\($0.normalizedEmail)|\($0.organizationId ?? "-")"
            }
        }
    }

    private func makeRetiredCredential(
        provider: ProviderKind,
        recordID: UUID,
        keychainAccount: String,
        stableIdentity: String?,
        purgeAfter: Date,
        now: Date
    ) -> RetiredCredential {
        RetiredCredential(
            id: UUID(),
            provider: provider,
            sourceRecordID: recordID,
            keychainAccount: keychainAccount,
            stableIdentity: stableIdentity,
            retiredAt: now,
            purgeAfter: purgeAfter
        )
    }
}
