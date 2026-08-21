import Foundation
import Testing
@testable import LimitsCore

@Test func repositoryMigratesV2OnceAndKeepsFutureSchemaReadOnly() async throws {
    let root = temporaryRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = AccountsPersistence(baseURL: root)
    let legacy = PersistedStateV5(schemaVersion: 2, revision: 4, accounts: [])
    try persistence.save(legacy)
    let originalData = try persistence.loadData()
    let original = try #require(originalData)
    let repository = AccountsRepository(persistence: persistence, vault: KeychainAuthVault(store: MemoryKeychainStore()))

    let migrated = try await repository.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)
    #expect(migrated.access == .readWrite)
    #expect(migrated.state.schemaVersion == PersistedStateV5.currentSchemaVersion)
    #expect(migrated.state.revision == 5)
    #expect(try Data(contentsOf: persistence.preV4BackupURL) == original)

    let futureData = Data("{\"schemaVersion\":99,\"revision\":12,\"accounts\":[],\"claudeAccounts\":[],\"retiredCredentials\":[]}".utf8)
    try futureData.write(to: persistence.stateURL, options: .atomic)
    let futureRepository = AccountsRepository(persistence: persistence, vault: KeychainAuthVault(store: MemoryKeychainStore()))
    let future = try await futureRepository.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)
    #expect(future.access == .readOnlyRecovery(reason: .accountsSchema(schemaVersion: 99)))
    await #expect(throws: AccountsRepositoryError.self) {
        try await futureRepository.deleteAccount(provider: .codex, accountID: UUID())
    }
    #expect(try Data(contentsOf: persistence.stateURL) == futureData)
}

@Test func repositoryCredentialReplacementIsCopyOnWriteAndRetiresOldReference() async throws {
    let root = temporaryRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MemoryKeychainStore()
    let repository = AccountsRepository(
        persistence: AccountsPersistence(baseURL: root),
        vault: KeychainAuthVault(store: store)
    )
    _ = try await repository.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)
    let account = repositoryAccount(fingerprint: "one")
    let first = try await repository.saveCodexAccount(account, credential: Data("one".utf8), now: .distantPast)
    let firstReference = try #require(first.state.accounts.first?.keychainAccount)

    var rotated = account
    rotated.authFingerprint = "two"
    let now = Date(timeIntervalSince1970: 2_000_000)
    let second = try await repository.saveCodexAccount(rotated, credential: Data("two".utf8), now: now)
    let secondReference = try #require(second.state.accounts.first?.keychainAccount)

    #expect(firstReference != secondReference)
    #expect(store.data(for: firstReference) == Data("one".utf8))
    #expect(store.data(for: secondReference) == Data("two".utf8))
    #expect(second.state.retiredCredentials.first?.keychainAccount == firstReference)
    #expect(second.state.retiredCredentials.first?.purgeAfter == now.addingTimeInterval(PersistedStateMigrator.retiredCredentialRetention))

    _ = try await repository.purgeRetiredCredentials(now: now.addingTimeInterval(PersistedStateMigrator.retiredCredentialRetention + 1))
    #expect(store.data(for: firstReference) == nil)
    #expect(store.data(for: secondReference) == Data("two".utf8))
}

@Test func repositoryFaultsBeforeCommitNeverLeaveAnOrphanCredential() async throws {
    for checkpoint in [AccountsRepositoryCheckpoint.afterReload, .afterCredentialWrite, .beforeStateWrite] {
        let root = temporaryRepositoryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryKeychainStore()
        let fault = RepositoryFault(checkpoint)
        let repository = AccountsRepository(
            persistence: AccountsPersistence(baseURL: root),
            vault: KeychainAuthVault(store: store),
            faultInjector: { try fault.check($0) }
        )
        _ = try await repository.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)

        await #expect(throws: RepositoryInjectedFailure.self) {
            try await repository.saveCodexAccount(repositoryAccount(fingerprint: "one"), credential: Data("secret".utf8))
        }
        #expect(store.allAccounts.isEmpty)
        #expect(try AccountsPersistence(baseURL: root).load().accounts.isEmpty)
    }
}

@Test func repositoryFaultAfterAtomicStateCommitKeepsTheReferencedCredential() async throws {
    let root = temporaryRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MemoryKeychainStore()
    let fault = RepositoryFault(.afterStateWrite)
    let persistence = AccountsPersistence(baseURL: root)
    let repository = AccountsRepository(
        persistence: persistence,
        vault: KeychainAuthVault(store: store),
        faultInjector: { try fault.check($0) }
    )
    _ = try await repository.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)
    await #expect(throws: RepositoryInjectedFailure.self) {
        try await repository.saveCodexAccount(repositoryAccount(fingerprint: "one"), credential: Data("secret".utf8))
    }
    let state = try persistence.load()
    let reference = try #require(state.accounts.first?.keychainAccount)
    #expect(store.data(for: reference) == Data("secret".utf8))
}

@Test func repositoryDetectsStaleRevisionAcrossProcessesAndReloadsBeforeUnconditionalMutation() async throws {
    let root = temporaryRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MemoryKeychainStore()
    let persistence = AccountsPersistence(baseURL: root)
    let firstRepository = AccountsRepository(persistence: persistence, vault: KeychainAuthVault(store: store))
    let secondRepository = AccountsRepository(persistence: persistence, vault: KeychainAuthVault(store: store))
    let firstOpen = try await firstRepository.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)
    let secondOpen = try await secondRepository.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)

    _ = try await firstRepository.saveCodexAccount(
        repositoryAccount(label: "First", fingerprint: "one"),
        credential: Data("one".utf8),
        expectedRevision: firstOpen.state.revision
    )
    await #expect(throws: AccountsRepositoryError.self) {
        try await secondRepository.saveCodexAccount(
            repositoryAccount(label: "Stale", fingerprint: "stale"),
            credential: Data("stale".utf8),
            expectedRevision: secondOpen.state.revision
        )
    }

    let merged = try await secondRepository.saveCodexAccount(
        repositoryAccount(label: "Second", fingerprint: "two"),
        credential: Data("two".utf8)
    )
    #expect(Set(merged.state.accounts.map(\.label)) == ["First", "Second"])
    #expect(merged.state.revision == 2)
}

@Test func repositoryRenameChangesOnlyTheLabelAcrossAStaleProcess() async throws {
    let root = temporaryRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MemoryKeychainStore()
    let persistence = AccountsPersistence(baseURL: root)
    let firstRepository = AccountsRepository(persistence: persistence, vault: KeychainAuthVault(store: store))
    let secondRepository = AccountsRepository(persistence: persistence, vault: KeychainAuthVault(store: store))
    _ = try await firstRepository.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)
    let account = repositoryAccount(label: "Original", fingerprint: "rename")
    let saved = try await firstRepository.saveCodexAccount(account, credential: Data("credential".utf8))
    let savedAccount = try #require(saved.state.accounts.first)
    let credentialReference = savedAccount.keychainAccount
    _ = try await secondRepository.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)

    var concurrentlyValidated = savedAccount
    concurrentlyValidated.status = .limitReached
    concurrentlyValidated.statusMessage = "Limit Reached"
    _ = try await firstRepository.updateCodexAccount(concurrentlyValidated)

    let renamed = try await secondRepository.renameAccount(
        provider: .codex,
        accountID: account.id,
        label: "Anything I Want",
        now: Date(timeIntervalSince1970: 2_000_000)
    )
    let result = try #require(renamed.state.accounts.first)

    #expect(result.label == "Anything I Want")
    #expect(result.status == .limitReached)
    #expect(result.statusMessage == "Limit Reached")
    #expect(result.keychainAccount == credentialReference)
    #expect(store.data(for: credentialReference) == Data("credential".utf8))
}

@Test func repositoryRenamePreservesClaudeIdentityAndCredential() async throws {
    let root = temporaryRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MemoryKeychainStore()
    let repository = AccountsRepository(
        persistence: AccountsPersistence(baseURL: root),
        vault: KeychainAuthVault(store: store)
    )
    _ = try await repository.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)
    let account = repositoryClaudeAccount(label: "Original", fingerprint: "claude-rename")
    let saved = try await repository.saveClaudeAccount(account, credential: Data("claude-credential".utf8))
    let savedAccount = try #require(saved.state.claudeAccounts.first)

    let renamed = try await repository.renameAccount(
        provider: .claude,
        accountID: account.id,
        label: "My Claude Account"
    )
    let result = try #require(renamed.state.claudeAccounts.first)

    #expect(result.label == "My Claude Account")
    #expect(result.email == account.email)
    #expect(result.orgId == account.orgId)
    #expect(result.keychainAccount == savedAccount.keychainAccount)
    #expect(store.data(for: result.keychainAccount) == Data("claude-credential".utf8))
}

@Test func repositoryDeletionCommitsStateBeforeDeferredKeychainCleanup() async throws {
    let root = temporaryRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MemoryKeychainStore()
    let persistence = AccountsPersistence(baseURL: root)
    let usage = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    let repository = AccountsRepository(
        persistence: persistence,
        usageRepository: usage,
        vault: KeychainAuthVault(store: store)
    )
    _ = try await repository.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)
    let account = repositoryAccount(fingerprint: "one")
    let saved = try await repository.saveCodexAccount(account, credential: Data("one".utf8))
    let reference = try #require(saved.state.accounts.first?.keychainAccount)
    store.failDeletes = true

    let deleted = try await repository.deleteAccount(provider: .codex, accountID: account.id)
    #expect(deleted.state.accounts.isEmpty)
    #expect(deleted.state.retiredCredentials.isEmpty)
    #expect(deleted.state.pendingAccountCleanups.contains { $0.keychainAccount == reference })
    #expect(store.data(for: reference) == Data("one".utf8))

    store.failDeletes = false
    await repository.close()
    let reopened = AccountsRepository(
        persistence: persistence,
        usageRepository: usage,
        vault: KeychainAuthVault(store: store)
    )
    let recovered = try await reopened.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)
    #expect(recovered.state.accounts.isEmpty)
    #expect(recovered.state.pendingAccountCleanups.isEmpty)
    #expect(store.data(for: reference) == nil)
}

@Test func repositoryKeychainWriteFailureLeavesStateUntouched() async throws {
    let root = temporaryRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MemoryKeychainStore()
    store.failSaves = true
    let persistence = AccountsPersistence(baseURL: root)
    let repository = AccountsRepository(persistence: persistence, vault: KeychainAuthVault(store: store))
    _ = try await repository.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)
    await #expect(throws: KeychainAuthVaultError.self) {
        try await repository.saveCodexAccount(repositoryAccount(fingerprint: "one"), credential: Data("secret".utf8))
    }
    #expect(try persistence.load().accounts.isEmpty)
}

@Test func repositoryRevisionNeverWrapsAndLeavesNoCredentialOrphan() async throws {
    let root = temporaryRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MemoryKeychainStore()
    let persistence = AccountsPersistence(baseURL: root)
    try persistence.save(PersistedStateV5(revision: .max, accounts: []))
    let repository = AccountsRepository(persistence: persistence, vault: KeychainAuthVault(store: store))
    _ = try await repository.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)

    do {
        _ = try await repository.saveCodexAccount(
            repositoryAccount(fingerprint: "overflow"), credential: Data("secret".utf8)
        )
        Issue.record("Expected revision exhaustion")
    } catch let error as AccountsRepositoryError {
        #expect(error == .revisionExhausted)
    }
    #expect(try persistence.load().revision == .max)
    #expect(store.allAccounts.isEmpty)
}

@Test func repositoryMigratesV3LimitsIntoSQLiteBeforeSwitchingStateToV5() async throws {
    let root = temporaryRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = AccountsPersistence(baseURL: root)
    try persistence.save(PersistedStateV5(accounts: []))
    let legacyData = legacyV3StateData()
    try legacyData.write(to: persistence.stateURL, options: .atomic)
    let usage = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    let repository = AccountsRepository(
        persistence: persistence,
        usageRepository: usage,
        vault: KeychainAuthVault(store: MemoryKeychainStore())
    )

    let opened = try await repository.open(currentCodexFingerprint: "legacy-fingerprint", currentClaudeFingerprint: nil)
    let usageSnapshot = try await usage.snapshot()

    #expect(opened.state.schemaVersion == PersistedStateV5.currentSchemaVersion)
    #expect(opened.state.accounts.first?.accountId == "acct_legacy")
    #expect(usageSnapshot.limitObservations["acct_legacy"]?.count == 2)
    #expect(usageSnapshot.latestLimits["acct_legacy"]?.primary?.primary?.usedPercent == 31)
    #expect(try Data(contentsOf: persistence.preV4BackupURL) == legacyData)
    let persistedText = String(decoding: try Data(contentsOf: persistence.stateURL), as: UTF8.self)
    #expect(!persistedText.contains("lastRateLimit"))
}

@Test func interruptedV3MigrationRetriesWithoutDuplicatingSQLiteObservations() async throws {
    let root = temporaryRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = AccountsPersistence(baseURL: root)
    try persistence.save(PersistedStateV5(accounts: []))
    let legacyData = legacyV3StateData()
    try legacyData.write(to: persistence.stateURL, options: .atomic)
    let usage = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    let fault = RepositoryFault(.beforeStateWrite)
    let interrupted = AccountsRepository(
        persistence: persistence,
        usageRepository: usage,
        vault: KeychainAuthVault(store: MemoryKeychainStore()),
        faultInjector: { try fault.check($0) }
    )

    await #expect(throws: RepositoryInjectedFailure.self) {
        try await interrupted.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)
    }
    #expect(try JSONDecoder.limits.decode(PersistedStateV5.self, from: Data(contentsOf: persistence.stateURL)).schemaVersion == 3)
    #expect(try await usage.snapshot().limitObservations["acct_legacy"]?.count == 2)

    let retry = AccountsRepository(
        persistence: persistence,
        usageRepository: usage,
        vault: KeychainAuthVault(store: MemoryKeychainStore())
    )
    let opened = try await retry.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)
    #expect(opened.state.schemaVersion == PersistedStateV5.currentSchemaVersion)
    #expect(try await usage.snapshot().limitObservations["acct_legacy"]?.count == 2)
}

@Test func deletingCodexAccountCascadesIntoUsageRepository() async throws {
    let root = temporaryRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = AccountsPersistence(baseURL: root)
    let usage = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    let repository = AccountsRepository(
        persistence: persistence,
        usageRepository: usage,
        vault: KeychainAuthVault(store: MemoryKeychainStore())
    )
    _ = try await repository.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)
    let account = repositoryAccount(fingerprint: "cascade")
    _ = try await repository.saveCodexAccount(account, credential: Data("secret".utf8))
    let accountID = try #require(account.accountId)
    let event = CodexUsageEvent(
        threadID: "thread",
        turnID: "turn",
        counterEpoch: 0,
        occurredAt: .now,
        accountID: accountID,
        requestedModel: "gpt-5.6-sol",
        billedModel: nil,
        reasoningEffort: "high",
        speed: nil,
        usage: CodexTokenUsage(inputTokens: 100, outputTokens: 20, totalTokens: 120),
        attribution: .confirmed,
        source: .localRollout
    )
    _ = try await usage.recordUsageEvents([event])
    try await usage.recordRateLimits(
        CodexRateLimitsSnapshot(accountID: accountID, observedAt: .now, primary: nil, byLimitID: nil, errorMessage: nil)
    )

    _ = try await repository.deleteAccount(provider: .codex, accountID: account.id)
    let snapshot = try await usage.snapshot()
    #expect(!snapshot.dailyUsage.contains { $0.accountID == accountID })
    #expect(snapshot.latestLimits[accountID] == nil)
}

private struct RepositoryInjectedFailure: Error {}

private final class RepositoryFault: @unchecked Sendable {
    private let checkpoint: AccountsRepositoryCheckpoint
    init(_ checkpoint: AccountsRepositoryCheckpoint) { self.checkpoint = checkpoint }
    func check(_ actual: AccountsRepositoryCheckpoint) throws {
        if actual == checkpoint { throw RepositoryInjectedFailure() }
    }
}

private final class MemoryKeychainStore: KeychainAuthDataStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var shouldFailDeletes = false
    private var shouldFailSaves = false

    var failDeletes: Bool {
        get { lock.withLock { shouldFailDeletes } }
        set { lock.withLock { shouldFailDeletes = newValue } }
    }
    var failSaves: Bool {
        get { lock.withLock { shouldFailSaves } }
        set { lock.withLock { shouldFailSaves = newValue } }
    }

    var allAccounts: Set<String> { lock.withLock { Set(values.keys) } }
    func data(for account: String) -> Data? { lock.withLock { values[account] } }
    func save(_ data: Data, account: String, label: String) throws {
        try lock.withLock {
            if shouldFailSaves { throw KeychainAuthVaultError.missingEntry }
            values[account] = data
        }
    }
    func read(account: String) throws -> Data {
        try lock.withLock {
            guard let data = values[account] else { throw KeychainAuthVaultError.missingEntry }
            return data
        }
    }
    func delete(account: String) throws {
        try lock.withLock {
            if shouldFailDeletes { throw KeychainAuthVaultError.missingEntry }
            values.removeValue(forKey: account)
        }
    }
}

private func temporaryRepositoryRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "limits-repository-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func repositoryAccount(label: String = "Account", fingerprint: String) -> StoredAccount {
    StoredAccount(
        id: UUID(), label: label, email: "\(label.lowercased())@example.com", accountId: "acct_\(fingerprint)",
        planType: "pro", createdAt: .distantPast, updatedAt: .distantPast, lastValidatedAt: nil,
        status: .ok, statusMessage: nil, authFingerprint: fingerprint, keychainAccount: "legacy.\(fingerprint)"
    )
}

private func repositoryClaudeAccount(label: String, fingerprint: String) -> ClaudeStoredAccount {
    ClaudeStoredAccount(
        id: UUID(),
        label: label,
        email: "claude@example.com",
        subscriptionType: "max",
        authMethod: "claude.ai",
        orgId: "org_fixture",
        orgName: "Fixture Org",
        createdAt: .distantPast,
        updatedAt: .distantPast,
        lastValidatedAt: nil,
        status: .ok,
        statusMessage: nil,
        authFingerprint: fingerprint,
        keychainAccount: "legacy.\(fingerprint)"
    )
}

private func legacyV3StateData() -> Data {
    Data(
        """
        {
          "schemaVersion": 3,
          "revision": 9,
          "accounts": [{
            "id": "E621E6F8-C36C-495A-93FC-2C07A5F7D319",
            "label": "Legacy",
            "email": "legacy@example.com",
            "accountId": "acct_legacy",
            "planType": "pro",
            "createdAt": "2026-08-01T00:00:00Z",
            "updatedAt": "2026-08-20T00:00:00Z",
            "lastValidatedAt": "2026-08-20T00:00:00Z",
            "status": "ok",
            "authFingerprint": "legacy-fingerprint",
            "keychainAccount": "legacy-keychain",
            "lastRateLimitObservedAt": "2026-08-20T00:00:00Z",
            "lastRateLimit": {
              "limitId": "codex",
              "planType": "pro",
              "primary": {"usedPercent": 31, "resetsAt": 1787202000, "windowDurationMins": 300},
              "secondary": {"usedPercent": 57, "resetsAt": 1787760000, "windowDurationMins": 10080}
            },
            "lastRateLimitsByLimitId": {}
          }],
          "claudeAccounts": [],
          "retiredCredentials": []
        }
        """.utf8
    )
}

@Test func futureUsageSchemaMakesTheWholeAccountDomainReadOnlyBeforeDelete() async throws {
    let root = temporaryRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = AccountsPersistence(baseURL: root)
    let account = repositoryAccount(fingerprint: "future-usage")
    try persistence.save(PersistedStateV5(accounts: [account]))
    let store = MemoryKeychainStore()
    try store.save(Data("secret".utf8), account: account.keychainAccount, label: account.label)

    let database = root.appending(path: "usage.sqlite3")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [database.path, "PRAGMA user_version = 999;"]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    let usage = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    let repository = AccountsRepository(
        persistence: persistence,
        usageRepository: usage,
        vault: KeychainAuthVault(store: store)
    )
    let opened = try await repository.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)
    #expect(opened.access == .readOnlyRecovery(reason: .usageSchema(schemaVersion: 999)))

    await #expect(throws: AccountsRepositoryError.self) {
        try await repository.deleteAccount(provider: .codex, accountID: account.id)
    }
    let disk = try persistence.load()
    #expect(disk.accounts == [account])
    #expect(disk.pendingAccountCleanups.isEmpty)
    #expect(store.data(for: account.keychainAccount) == Data("secret".utf8))
    await repository.close()
}

@Test func futureAccountsSchemaIsDetectedBeforeOpeningUsageStorage() async throws {
    let root = temporaryRepositoryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = AccountsPersistence(baseURL: root)
    let future = PersistedStateV5(schemaVersion: 99, accounts: [])
    try persistence.save(future)
    let usage = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    let repository = AccountsRepository(
        persistence: persistence,
        usageRepository: usage,
        vault: KeychainAuthVault(store: MemoryKeychainStore())
    )

    let opened = try await repository.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)

    #expect(opened.access == .readOnlyRecovery(reason: .accountsSchema(schemaVersion: 99)))
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "usage.sqlite3").path))
    await repository.close()
}
