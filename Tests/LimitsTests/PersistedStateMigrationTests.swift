import Foundation
import Testing
@testable import Limits

@Test func v1MigrationMergesStableIdentityAndRetainsLosingCredential() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let current = makeMigrationAccount(
        label: "Current",
        accountId: "acct_same",
        fingerprint: "current-fingerprint",
        status: .needsReauth,
        validatedAt: now.addingTimeInterval(-500)
    )
    let duplicate = makeMigrationAccount(
        label: "Duplicate",
        accountId: "acct_same",
        fingerprint: "other-fingerprint",
        status: .ok,
        validatedAt: now
    )
    let source = PersistedState(
        schemaVersion: 1,
        accounts: [duplicate, current]
    )

    let result = PersistedStateMigrator.migrate(
        source,
        currentCodexFingerprint: current.authFingerprint,
        currentClaudeFingerprint: nil,
        now: now
    )

    #expect(result.state.schemaVersion == 2)
    #expect(result.state.accounts.map(\.id) == [current.id])
    #expect(result.state.retiredCredentials.count == 1)
    #expect(result.state.retiredCredentials[0].keychainAccount == duplicate.keychainAccount)
    #expect(result.state.retiredCredentials[0].purgeAfter == now.addingTimeInterval(PersistedStateMigrator.retiredCredentialRetention))
    #expect(result.receipt.retiredCredentialCount == 1)
}

@Test func v1MigrationPrefersNewestHealthyCredentialWithoutCurrentMatch() throws {
    let now = Date(timeIntervalSince1970: 20_000)
    let failed = makeMigrationAccount(
        label: "Failed",
        accountId: "acct_same",
        fingerprint: "failed",
        status: .validationFailed,
        validatedAt: now
    )
    let healthy = makeMigrationAccount(
        label: "Healthy",
        accountId: "acct_same",
        fingerprint: "healthy",
        status: .ok,
        validatedAt: now.addingTimeInterval(-100)
    )

    let result = PersistedStateMigrator.migrate(
        PersistedState(schemaVersion: 1, accounts: [failed, healthy]),
        currentCodexFingerprint: nil,
        currentClaudeFingerprint: nil,
        now: now
    )

    #expect(result.state.accounts.map(\.id) == [healthy.id])
    #expect(result.state.retiredCredentials.map(\.sourceRecordID) == [failed.id])
}

@Test func v2MigrationIsIdempotent() {
    let account = makeMigrationAccount(
        label: "Only",
        accountId: "acct_only",
        fingerprint: "fingerprint",
        status: .ok,
        validatedAt: .now
    )
    let source = PersistedState(accounts: [account])

    let result = PersistedStateMigrator.migrate(
        source,
        currentCodexFingerprint: account.authFingerprint,
        currentClaudeFingerprint: nil
    )

    #expect(!result.receipt.didChange)
    #expect(result.state.accounts == source.accounts)
    #expect(result.state.retiredCredentials.isEmpty)
}

@Test func migrationNeverRetiresAKeychainEntryStillUsedByWinner() {
    let now = Date(timeIntervalSince1970: 30_000)
    let first = makeMigrationAccount(
        label: "First",
        accountId: "acct_same",
        fingerprint: "first",
        status: .ok,
        validatedAt: now
    )
    var second = makeMigrationAccount(
        label: "Second",
        accountId: "acct_same",
        fingerprint: "second",
        status: .needsReauth,
        validatedAt: now.addingTimeInterval(-100)
    )
    second.keychainAccount = first.keychainAccount

    let result = PersistedStateMigrator.migrate(
        PersistedState(schemaVersion: 1, accounts: [first, second]),
        currentCodexFingerprint: first.authFingerprint,
        currentClaudeFingerprint: nil,
        now: now
    )

    #expect(result.state.accounts.map(\.id) == [first.id])
    #expect(result.state.retiredCredentials.isEmpty)
}

@Test func persistenceSecuresStateAndPreMigrationBackup() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "limits-persistence-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = AccountsPersistence(baseURL: root)
    let legacyData = Data("{\"accounts\":[]}".utf8)

    try persistence.backupBeforeV2Migration(legacyData)
    try persistence.save(PersistedState(accounts: []))

    #expect(try Data(contentsOf: persistence.preV2BackupURL) == legacyData)
    #expect(posixPermissions(at: persistence.stateDirectoryURL) == 0o700)
    #expect(posixPermissions(at: persistence.stateURL) == 0o600)
    #expect(posixPermissions(at: persistence.preV2BackupURL) == 0o600)
}

private func makeMigrationAccount(
    label: String,
    accountId: String,
    fingerprint: String,
    status: AccountStatus,
    validatedAt: Date
) -> StoredAccount {
    let id = UUID()
    return StoredAccount(
        id: id,
        label: label,
        email: "user@example.com",
        accountId: accountId,
        planType: "pro",
        createdAt: validatedAt.addingTimeInterval(-1_000),
        updatedAt: validatedAt,
        lastValidatedAt: validatedAt,
        status: status,
        statusMessage: nil,
        lastRateLimit: nil,
        lastRateLimitsByLimitId: nil,
        authFingerprint: fingerprint,
        keychainAccount: "account.\(id.uuidString)"
    )
}

private func posixPermissions(at url: URL) -> Int {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
