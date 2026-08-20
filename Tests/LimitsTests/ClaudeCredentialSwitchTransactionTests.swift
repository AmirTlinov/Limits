import Foundation
import Testing
@testable import LimitsCore

@Test func claudeSwitchCommitsOnlyAfterIdentityValidation() async throws {
    let original = Data("original".utf8)
    let replacement = Data("selected".utf8)
    let store = InMemoryClaudeCredentialStore(data: original)
    let reader = ClosureClaudeStatusReader { makeClaudeStatus(email: "selected@example.com", orgID: "org_1") }
    let transaction = ClaudeCredentialSwitchTransaction(globalStore: store, statusReader: reader)
    let preparation = ClaudePreparationRecorder()

    let result = try await transaction.execute(
        account: makeClaudeSwitchAccount(email: "selected@example.com", orgID: "org_1"),
        credential: replacement
    ) { prepared in
        #expect(prepared.credential == replacement)
        await preparation.markPrepared()
    }

    #expect(await preparation.wasPrepared)
    #expect(result.credential == replacement)
    #expect(store.currentData == replacement)
    #expect(store.restoreCount == 0)
}

@Test func claudeSwitchRollsBackCredentialForWrongIdentity() async throws {
    let original = Data("original".utf8)
    let replacement = Data("selected".utf8)
    let store = InMemoryClaudeCredentialStore(data: original)
    let reader = ClosureClaudeStatusReader { makeClaudeStatus(email: "other@example.com", orgID: "org_2") }
    let transaction = ClaudeCredentialSwitchTransaction(globalStore: store, statusReader: reader)

    do {
        _ = try await transaction.execute(
            account: makeClaudeSwitchAccount(email: "selected@example.com", orgID: "org_1"),
            credential: replacement
        )
        Issue.record("Expected identity mismatch")
    } catch ClaudeCredentialSwitchTransactionError.identityMismatch {
        // Expected.
    }

    #expect(store.currentData == original)
    #expect(store.restoreCount == 1)
}

@Test func claudeSwitchRollsBackWhenStatusCommandFails() async throws {
    let original = Data("original".utf8)
    let replacement = Data("selected".utf8)
    let store = InMemoryClaudeCredentialStore(data: original)
    let reader = ClosureClaudeStatusReader { throw ClaudeSwitchTestError.statusFailed }
    let transaction = ClaudeCredentialSwitchTransaction(globalStore: store, statusReader: reader)

    do {
        _ = try await transaction.execute(
            account: makeClaudeSwitchAccount(email: "selected@example.com", orgID: "org_1"),
            credential: replacement
        )
        Issue.record("Expected status failure")
    } catch ClaudeSwitchTestError.statusFailed {
        // Expected.
    }

    #expect(store.currentData == original)
    #expect(store.restoreCount == 1)
}

@Test func claudeSwitchPreservesExternalMutationInsteadOfRollingItBack() async throws {
    let original = Data("original".utf8)
    let replacement = Data("selected".utf8)
    let external = Data("external".utf8)
    let store = InMemoryClaudeCredentialStore(data: original)
    let reader = ClosureClaudeStatusReader {
        store.replaceExternally(with: external)
        throw ClaudeSwitchTestError.statusFailed
    }
    let transaction = ClaudeCredentialSwitchTransaction(globalStore: store, statusReader: reader)

    do {
        _ = try await transaction.execute(
            account: makeClaudeSwitchAccount(email: "selected@example.com", orgID: "org_1"),
            credential: replacement
        )
        Issue.record("Expected concurrent mutation")
    } catch GlobalClaudeCredentialServiceError.concurrentModification {
        // Expected.
    }

    #expect(store.currentData == external)
    #expect(store.restoreCount == 0)
}

@Test func claudeSwitchPersistsCredentialRotationAfterSecondStableProbe() async throws {
    let original = Data("original".utf8)
    let replacement = Data("selected".utf8)
    let rotated = Data("rotated".utf8)
    let store = InMemoryClaudeCredentialStore(data: original)
    let probe = ClaudeStatusProbeCounter()
    let reader = ClosureClaudeStatusReader {
        let count = await probe.increment()
        if count == 1 {
            store.replaceExternally(with: rotated)
        }
        return makeClaudeStatus(email: "selected@example.com", orgID: "org_1")
    }
    let transaction = ClaudeCredentialSwitchTransaction(globalStore: store, statusReader: reader)

    let result = try await transaction.execute(
        account: makeClaudeSwitchAccount(email: "selected@example.com", orgID: "org_1"),
        credential: replacement
    )

    #expect(result.credential == rotated)
    #expect(store.currentData == rotated)
    #expect(await probe.count == 2)
}

@Test func claudeRepositoryFailurePreservesCredentialRotatedByClaude() async throws {
    let original = Data("original".utf8)
    let replacement = Data("selected".utf8)
    let rotated = Data("rotated".utf8)
    let store = InMemoryClaudeCredentialStore(data: original)
    let probe = ClaudeStatusProbeCounter()
    let reader = ClosureClaudeStatusReader {
        let count = await probe.increment()
        if count == 1 {
            store.replaceExternally(with: rotated)
        }
        return makeClaudeStatus(email: "selected@example.com", orgID: "org_1")
    }
    let transaction = ClaudeCredentialSwitchTransaction(globalStore: store, statusReader: reader)

    do {
        _ = try await transaction.execute(
            account: makeClaudeSwitchAccount(email: "selected@example.com", orgID: "org_1"),
            credential: replacement
        ) { _ in
            throw ClaudeSwitchTestError.repositoryFailed
        }
        Issue.record("Expected repository failure")
    } catch ClaudeSwitchTestError.repositoryFailed {
        // The repository error is the honest outcome; Claude's newer credential stays global.
    }

    #expect(store.currentData == rotated)
    #expect(store.restoreCount == 0)
}

private struct ClosureClaudeStatusReader: ClaudeAuthStatusReading {
    let operation: @Sendable () async throws -> ClaudeAuthStatus

    init(operation: @escaping @Sendable () async throws -> ClaudeAuthStatus) {
        self.operation = operation
    }

    func readStatus() async throws -> ClaudeAuthStatus {
        try await operation()
    }
}

private final class InMemoryClaudeCredentialStore: GlobalClaudeCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let account = "test-user"
    private var data: Data?
    private(set) var restoreCount = 0

    init(data: Data?) {
        self.data = data
    }

    var currentData: Data? {
        lock.withLock { data }
    }

    func readSnapshot() throws -> GlobalClaudeCredentialSnapshot {
        lock.withLock {
            GlobalClaudeCredentialSnapshot(account: data == nil ? nil : account, data: data)
        }
    }

    func commit(expected: GlobalClaudeCredentialSnapshot, replacement: Data) throws {
        try lock.withLock {
            let current = GlobalClaudeCredentialSnapshot(account: data == nil ? nil : account, data: data)
            guard current == expected else {
                throw GlobalClaudeCredentialServiceError.concurrentModification
            }
            data = replacement
        }
    }

    func verifyCommitted(_ replacement: Data, basedOn original: GlobalClaudeCredentialSnapshot) throws {
        try lock.withLock {
            guard data == replacement else {
                throw GlobalClaudeCredentialServiceError.committedDataMismatch
            }
        }
    }

    func restore(_ original: GlobalClaudeCredentialSnapshot, replacing replacement: Data) throws {
        try lock.withLock {
            guard data == replacement else {
                throw GlobalClaudeCredentialServiceError.concurrentModification
            }
            data = original.data
            restoreCount += 1
        }
    }

    func replaceExternally(with replacement: Data) {
        lock.withLock {
            data = replacement
        }
    }
}

private actor ClaudePreparationRecorder {
    private(set) var wasPrepared = false

    func markPrepared() {
        wasPrepared = true
    }
}

private actor ClaudeStatusProbeCounter {
    private(set) var count = 0

    func increment() -> Int {
        count += 1
        return count
    }
}

private enum ClaudeSwitchTestError: Error {
    case statusFailed
    case repositoryFailed
}

private func makeClaudeSwitchAccount(email: String, orgID: String?) -> ClaudeStoredAccount {
    let id = UUID()
    return ClaudeStoredAccount(
        id: id,
        label: email,
        email: email,
        subscriptionType: "max",
        authMethod: "claude.ai",
        orgId: orgID,
        orgName: nil,
        createdAt: .distantPast,
        updatedAt: .distantPast,
        lastValidatedAt: nil,
        status: .ok,
        statusMessage: nil,
        authFingerprint: "fingerprint",
        keychainAccount: "claude.\(id.uuidString)"
    )
}

private func makeClaudeStatus(email: String, orgID: String?) -> ClaudeAuthStatus {
    ClaudeAuthStatus(
        loggedIn: true,
        authMethod: "claude.ai",
        apiProvider: "firstParty",
        email: email,
        orgId: orgID,
        orgName: nil,
        subscriptionType: "max"
    )
}
