import Foundation

struct PersistedStateMigrationReceipt: Hashable {
    let sourceSchemaVersion: Int
    let targetSchemaVersion: Int
    let retiredCredentialCount: Int

    var didChange: Bool {
        sourceSchemaVersion != targetSchemaVersion || retiredCredentialCount > 0
    }
}

struct PersistedStateMigrationResult {
    let state: PersistedState
    let receipt: PersistedStateMigrationReceipt
}

enum PersistedStateMigrator {
    static let retiredCredentialRetention: TimeInterval = 30 * 24 * 60 * 60

    static func migrate(
        _ source: PersistedState,
        currentCodexFingerprint: String?,
        currentClaudeFingerprint: String?,
        now: Date = .now
    ) -> PersistedStateMigrationResult {
        guard source.schemaVersion < PersistedState.currentSchemaVersion else {
            return PersistedStateMigrationResult(
                state: source,
                receipt: PersistedStateMigrationReceipt(
                    sourceSchemaVersion: source.schemaVersion,
                    targetSchemaVersion: source.schemaVersion,
                    retiredCredentialCount: 0
                )
            )
        }

        var retired = source.retiredCredentials
        let codex = mergeCodexDuplicates(
            source.accounts,
            currentFingerprint: currentCodexFingerprint,
            retired: &retired,
            now: now
        )
        let claude = mergeClaudeDuplicates(
            source.claudeAccounts,
            currentFingerprint: currentClaudeFingerprint,
            retired: &retired,
            now: now
        )
        let activeKeychainAccounts = Set(codex.map(\.keychainAccount) + claude.map(\.keychainAccount))
        retired.removeAll { activeKeychainAccounts.contains($0.keychainAccount) }
        let newlyRetiredCount = max(0, retired.count - source.retiredCredentials.count)

        return PersistedStateMigrationResult(
            state: PersistedState(
                accounts: codex,
                claudeAccounts: claude,
                retiredCredentials: retired
            ),
            receipt: PersistedStateMigrationReceipt(
                sourceSchemaVersion: source.schemaVersion,
                targetSchemaVersion: PersistedState.currentSchemaVersion,
                retiredCredentialCount: newlyRetiredCount
            )
        )
    }

    private static func mergeCodexDuplicates(
        _ accounts: [StoredAccount],
        currentFingerprint: String?,
        retired: inout [RetiredCredential],
        now: Date
    ) -> [StoredAccount] {
        let grouped = Dictionary(grouping: accounts) { account -> String in
            account.stableIdentity.map { "account:\($0.accountId)" } ?? "record:\(account.id.uuidString)"
        }

        return grouped.values.compactMap { candidates in
            guard let winner = preferred(candidates, currentFingerprint: currentFingerprint) else {
                return nil
            }

            for loser in candidates where loser.id != winner.id {
                retire(
                    provider: .codex,
                    sourceRecordID: loser.id,
                    keychainAccount: loser.keychainAccount,
                    stableIdentity: loser.stableIdentity.map { "codex:\($0.accountId)" },
                    retired: &retired,
                    now: now
                )
            }
            return winner
        }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private static func mergeClaudeDuplicates(
        _ accounts: [ClaudeStoredAccount],
        currentFingerprint: String?,
        retired: inout [RetiredCredential],
        now: Date
    ) -> [ClaudeStoredAccount] {
        let grouped = Dictionary(grouping: accounts) { account -> String in
            guard let identity = account.stableIdentity else {
                return "record:\(account.id.uuidString)"
            }
            return "account:\(identity.normalizedEmail)|\(identity.organizationId ?? "-")"
        }

        return grouped.values.compactMap { candidates in
            guard let winner = preferred(candidates, currentFingerprint: currentFingerprint) else {
                return nil
            }

            for loser in candidates where loser.id != winner.id {
                let identity = loser.stableIdentity.map {
                    "claude:\($0.normalizedEmail)|\($0.organizationId ?? "-")"
                }
                retire(
                    provider: .claude,
                    sourceRecordID: loser.id,
                    keychainAccount: loser.keychainAccount,
                    stableIdentity: identity,
                    retired: &retired,
                    now: now
                )
            }
            return winner
        }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private static func preferred<Account>(
        _ candidates: [Account],
        currentFingerprint: String?
    ) -> Account? where Account: CredentialBackedAccount {
        candidates.max { lhs, rhs in
            preferenceTuple(lhs, currentFingerprint: currentFingerprint)
                < preferenceTuple(rhs, currentFingerprint: currentFingerprint)
        }
    }

    private static func preferenceTuple<Account>(
        _ account: Account,
        currentFingerprint: String?
    ) -> (Int, Int, Date, Date) where Account: CredentialBackedAccount {
        (
            currentFingerprint == account.authFingerprint ? 1 : 0,
            statusRank(account.status),
            account.lastValidatedAt ?? .distantPast,
            account.updatedAt
        )
    }

    private static func statusRank(_ status: AccountStatus) -> Int {
        switch status {
        case .ok, .limitReached:
            3
        case .unknown:
            2
        case .needsReauth:
            1
        case .validationFailed:
            0
        }
    }

    private static func retire(
        provider: ProviderKind,
        sourceRecordID: UUID,
        keychainAccount: String,
        stableIdentity: String?,
        retired: inout [RetiredCredential],
        now: Date
    ) {
        guard !retired.contains(where: { $0.keychainAccount == keychainAccount }) else {
            return
        }
        retired.append(
            RetiredCredential(
                id: UUID(),
                provider: provider,
                sourceRecordID: sourceRecordID,
                keychainAccount: keychainAccount,
                stableIdentity: stableIdentity,
                retiredAt: now,
                purgeAfter: now.addingTimeInterval(retiredCredentialRetention)
            )
        )
    }
}

private protocol CredentialBackedAccount {
    var authFingerprint: String { get }
    var status: AccountStatus { get }
    var lastValidatedAt: Date? { get }
    var updatedAt: Date { get }
}

extension StoredAccount: CredentialBackedAccount {}
extension ClaudeStoredAccount: CredentialBackedAccount {}
