import Foundation

public struct PersistedStateMigrationReceipt: Hashable, Sendable {
    public let sourceSchemaVersion: Int
    public let targetSchemaVersion: Int
    public let retiredCredentialCount: Int
    public let importedLimitObservationCount: Int

    public var didChange: Bool {
        sourceSchemaVersion != targetSchemaVersion || retiredCredentialCount > 0
    }
}

public struct PersistedStateMigrationResult: Sendable {
    public let state: PersistedStateV5
    public let legacyLimitObservations: [CodexLimitObservation]
    public let legacyRateLimitSnapshots: [CodexRateLimitsSnapshot]
    public let receipt: PersistedStateMigrationReceipt
}

public enum PersistedStateMigrator {
    public static let retiredCredentialRetention: TimeInterval = 30 * 24 * 60 * 60

    public static func decodeAndMigrate(
        _ data: Data,
        currentCodexFingerprint: String?,
        currentClaudeFingerprint: String?,
        now: Date = .now
    ) throws -> PersistedStateMigrationResult {
        let header = try JSONDecoder.limits.decode(SchemaHeader.self, from: data)
        if header.schemaVersion >= PersistedStateV5.currentSchemaVersion {
            return migrate(
                try JSONDecoder.limits.decode(PersistedStateV5.self, from: data),
                currentCodexFingerprint: currentCodexFingerprint,
                currentClaudeFingerprint: currentClaudeFingerprint,
                now: now
            )
        }

        let legacy = try JSONDecoder.limits.decode(LegacyPersistedState.self, from: data)
        let source = PersistedStateV5(
            schemaVersion: legacy.schemaVersion,
            revision: legacy.revision,
            accounts: legacy.accounts.map(\.account),
            claudeAccounts: legacy.claudeAccounts,
            retiredCredentials: legacy.retiredCredentials,
            pendingAccountCleanups: legacy.pendingAccountCleanups
        )
        let migrated = migrate(
            source,
            currentCodexFingerprint: currentCodexFingerprint,
            currentClaudeFingerprint: currentClaudeFingerprint,
            now: now
        )
        let retainedAccountIDs = Set(migrated.state.accounts.compactMap(\.accountId))
        let observations = legacy.accounts
            .filter { account in account.account.accountId.map(retainedAccountIDs.contains) == true }
            .flatMap(\.limitObservations)
        let snapshots = legacy.accounts
            .filter { account in account.account.accountId.map(retainedAccountIDs.contains) == true }
            .compactMap(\.rateLimitsSnapshot)

        return PersistedStateMigrationResult(
            state: migrated.state,
            legacyLimitObservations: observations,
            legacyRateLimitSnapshots: snapshots,
            receipt: PersistedStateMigrationReceipt(
                sourceSchemaVersion: legacy.schemaVersion,
                targetSchemaVersion: PersistedStateV5.currentSchemaVersion,
                retiredCredentialCount: migrated.receipt.retiredCredentialCount,
                importedLimitObservationCount: observations.count
            )
        )
    }

    public static func migrate(
        _ source: PersistedStateV5,
        currentCodexFingerprint: String?,
        currentClaudeFingerprint: String?,
        now: Date = .now
    ) -> PersistedStateMigrationResult {
        guard source.schemaVersion < PersistedStateV5.currentSchemaVersion else {
            return PersistedStateMigrationResult(
                state: source,
                legacyLimitObservations: [],
                legacyRateLimitSnapshots: [],
                receipt: PersistedStateMigrationReceipt(
                    sourceSchemaVersion: source.schemaVersion,
                    targetSchemaVersion: source.schemaVersion,
                    retiredCredentialCount: 0,
                    importedLimitObservationCount: 0
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
            state: PersistedStateV5(
                revision: source.revision,
                accounts: codex,
                claudeAccounts: claude,
                retiredCredentials: retired,
                pendingAccountCleanups: source.pendingAccountCleanups
            ),
            legacyLimitObservations: [],
            legacyRateLimitSnapshots: [],
            receipt: PersistedStateMigrationReceipt(
                sourceSchemaVersion: source.schemaVersion,
                targetSchemaVersion: PersistedStateV5.currentSchemaVersion,
                retiredCredentialCount: newlyRetiredCount,
                importedLimitObservationCount: 0
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
            guard let winner = preferred(candidates, currentFingerprint: currentFingerprint) else { return nil }
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
        let concreteOrganizationsByEmail = Dictionary(grouping: accounts.compactMap { account -> (String, String)? in
            guard let identity = account.stableIdentity, let organizationID = identity.organizationId else { return nil }
            return (identity.normalizedEmail, organizationID)
        }, by: \.0).mapValues { Set($0.map(\.1)) }

        let grouped = Dictionary(grouping: accounts) { account -> String in
            guard let identity = account.stableIdentity else { return "record:\(account.id.uuidString)" }
            if let organizationID = identity.organizationId {
                return "account:\(identity.normalizedEmail)|\(organizationID)"
            }
            let candidates = concreteOrganizationsByEmail[identity.normalizedEmail] ?? []
            if candidates.count == 1, let organizationID = candidates.first {
                return "account:\(identity.normalizedEmail)|\(organizationID)"
            }
            return "account:\(identity.normalizedEmail)|-"
        }

        return grouped.values.compactMap { candidates in
            guard let winner = preferred(candidates, currentFingerprint: currentFingerprint) else { return nil }
            var promotedWinner = winner
            if promotedWinner.orgId == nil,
               let identity = promotedWinner.stableIdentity,
               let organizations = concreteOrganizationsByEmail[identity.normalizedEmail],
               organizations.count == 1 {
                promotedWinner.orgId = organizations.first
                if let concrete = candidates.first(where: { $0.orgId == promotedWinner.orgId }) {
                    promotedWinner.orgName = promotedWinner.orgName ?? concrete.orgName
                }
            }
            for loser in candidates where loser.id != winner.id {
                retire(
                    provider: .claude,
                    sourceRecordID: loser.id,
                    keychainAccount: loser.keychainAccount,
                    stableIdentity: loser.stableIdentity.map { "claude:\($0.normalizedEmail)|\($0.organizationId ?? "-")" },
                    retired: &retired,
                    now: now
                )
            }
            return promotedWinner
        }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private static func preferred<Account>(
        _ candidates: [Account],
        currentFingerprint: String?
    ) -> Account? where Account: CredentialBackedAccount {
        candidates.max {
            preferenceTuple($0, currentFingerprint: currentFingerprint)
                < preferenceTuple($1, currentFingerprint: currentFingerprint)
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
        case .ok, .limitReached: 3
        case .unknown: 2
        case .needsReauth: 1
        case .validationFailed: 0
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
        guard !retired.contains(where: { $0.keychainAccount == keychainAccount }) else { return }
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

private struct SchemaHeader: Decodable {
    let schemaVersion: Int

    private enum CodingKeys: String, CodingKey { case schemaVersion }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }
}

private struct LegacyPersistedState: Decodable {
    let schemaVersion: Int
    let revision: UInt64
    let accounts: [LegacyStoredAccount]
    let claudeAccounts: [ClaudeStoredAccount]
    let retiredCredentials: [RetiredCredential]
    let pendingAccountCleanups: [PendingAccountCleanup]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, accounts, claudeAccounts, retiredCredentials, pendingAccountCleanups
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        revision = try container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        accounts = try container.decodeIfPresent([LegacyStoredAccount].self, forKey: .accounts) ?? []
        claudeAccounts = try container.decodeIfPresent([ClaudeStoredAccount].self, forKey: .claudeAccounts) ?? []
        retiredCredentials = try container.decodeIfPresent([RetiredCredential].self, forKey: .retiredCredentials) ?? []
        pendingAccountCleanups = try container.decodeIfPresent(
            [PendingAccountCleanup].self,
            forKey: .pendingAccountCleanups
        ) ?? []
    }
}

private struct LegacyStoredAccount: Decodable {
    let account: StoredAccount
    let lastRateLimit: RateLimitSnapshotModel?
    let lastRateLimitsByLimitID: [String: RateLimitSnapshotModel]?
    let observedAt: Date?
    let errorMessage: String?

    private enum CodingKeys: String, CodingKey {
        case id, label, email, accountId, planType, createdAt, updatedAt, lastValidatedAt
        case status, statusMessage, lastRateLimit, lastRateLimitsByLimitId
        case authFingerprint, keychainAccount, lastRateLimitObservedAt, subscriptionPeriod, limitsIssue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decodeIfPresent(AccountStatus.self, forKey: .status) ?? .unknown
        let legacyIssue = try container.decodeIfPresent(String.self, forKey: .limitsIssue)
        let normalizedStatus: AccountStatus
        if legacyIssue == "authorizationExpired" {
            normalizedStatus = .needsReauth
        } else if status == .limitReached {
            normalizedStatus = .ok
        } else {
            normalizedStatus = status
        }
        account = StoredAccount(
            id: try container.decode(UUID.self, forKey: .id),
            label: try container.decode(String.self, forKey: .label),
            email: try container.decode(String.self, forKey: .email),
            accountId: try container.decodeIfPresent(String.self, forKey: .accountId),
            planType: try container.decodeIfPresent(String.self, forKey: .planType) ?? "unknown",
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            lastValidatedAt: try container.decodeIfPresent(Date.self, forKey: .lastValidatedAt),
            status: normalizedStatus,
            statusMessage: normalizedStatus == .ok ? nil : try container.decodeIfPresent(String.self, forKey: .statusMessage),
            authFingerprint: try container.decodeIfPresent(String.self, forKey: .authFingerprint) ?? "",
            keychainAccount: try container.decodeIfPresent(String.self, forKey: .keychainAccount) ?? "",
            subscriptionPeriod: try container.decodeIfPresent(ChatGPTSubscriptionPeriod.self, forKey: .subscriptionPeriod)
        )
        lastRateLimit = try container.decodeIfPresent(RateLimitSnapshotModel.self, forKey: .lastRateLimit)
        lastRateLimitsByLimitID = try container.decodeIfPresent([String: RateLimitSnapshotModel].self, forKey: .lastRateLimitsByLimitId)
        observedAt = try container.decodeIfPresent(Date.self, forKey: .lastRateLimitObservedAt) ?? account.lastValidatedAt
        errorMessage = legacyIssue == nil ? nil : try container.decodeIfPresent(String.self, forKey: .statusMessage)
    }

    var limitObservations: [CodexLimitObservation] {
        guard let accountID = account.accountId, let observedAt else { return [] }
        let snapshots: [(String, RateLimitSnapshotModel)]
        if let byID = lastRateLimitsByLimitID, !byID.isEmpty {
            snapshots = byID.sorted { $0.key < $1.key }
        } else if let lastRateLimit {
            snapshots = [(lastRateLimit.limitId ?? "codex", lastRateLimit)]
        } else {
            snapshots = []
        }
        return snapshots.flatMap { limitID, snapshot in
            var result: [CodexLimitObservation] = []
            if let primary = snapshot.primary {
                result.append(makeObservation(accountID: accountID, limitID: limitID, window: .primary, snapshot: primary, observedAt: observedAt))
            }
            if let secondary = snapshot.secondary {
                result.append(makeObservation(accountID: accountID, limitID: limitID, window: .secondary, snapshot: secondary, observedAt: observedAt))
            }
            if let individual = snapshot.individualLimit {
                result.append(
                    CodexLimitObservation(
                        accountID: accountID,
                        limitID: limitID,
                        window: .individual,
                        observedAt: observedAt,
                        usedPercent: max(0, 100 - individual.remainingPercent),
                        resetsAt: Date(timeIntervalSince1970: TimeInterval(individual.resetsAt)),
                        windowDurationMinutes: nil
                    )
                )
            }
            return result
        }
    }

    var rateLimitsSnapshot: CodexRateLimitsSnapshot? {
        guard let accountID = account.accountId, let observedAt else { return nil }
        guard lastRateLimit != nil || lastRateLimitsByLimitID?.isEmpty == false || errorMessage != nil else { return nil }
        return CodexRateLimitsSnapshot(
            accountID: accountID,
            observedAt: observedAt,
            primary: lastRateLimit,
            byLimitID: lastRateLimitsByLimitID,
            errorMessage: errorMessage
        )
    }

    private func makeObservation(
        accountID: String,
        limitID: String,
        window: CodexLimitWindowKind,
        snapshot: RateLimitWindowSnapshot,
        observedAt: Date
    ) -> CodexLimitObservation {
        CodexLimitObservation(
            accountID: accountID,
            limitID: limitID,
            window: window,
            observedAt: observedAt,
            usedPercent: snapshot.usedPercent,
            resetsAt: snapshot.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            windowDurationMinutes: snapshot.windowDurationMins
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
