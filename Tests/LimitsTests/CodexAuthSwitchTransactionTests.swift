import Foundation
import Testing
@testable import LimitsCore

@Test func codexSwitchValidatesAndPersistsBeforeReplacingGlobalAuth() async throws {
    let fixture = try CodexSwitchFixture()
    defer { fixture.remove() }
    let selectedCredential = makeCodexAuthData(accountID: "acct_selected", version: 1)
    let refreshedCredential = makeCodexAuthData(accountID: "acct_selected", version: 2)
    let originalCredential = makeCodexAuthData(accountID: "acct_original", version: 1)
    try originalCredential.write(to: fixture.authURL)

    let validator = ClosureCodexValidator { input in
        #expect(input == selectedCredential)
        return makeValidationResult(authData: refreshedCredential, accountID: "acct_selected")
    }
    let transaction = CodexAuthSwitchTransaction(globalStore: fixture.store, validator: validator)
    let preparation = PreparationRecorder()

    let result = try await transaction.execute(
        account: makeSwitchAccount(accountID: "acct_selected", credential: selectedCredential),
        authData: selectedCredential
    ) { validated in
        let globalDuringPreparation = try Data(contentsOf: fixture.authURL)
        #expect(globalDuringPreparation == originalCredential)
        #expect(validated.authData == refreshedCredential)
        await preparation.markPrepared()
    }

    #expect(await preparation.wasPrepared)
    #expect(result.authData == refreshedCredential)
    #expect(try Data(contentsOf: fixture.authURL) == refreshedCredential)
    #expect(posixMode(at: fixture.authURL) == 0o600)
}

@Test func codexSwitchLeavesGlobalAuthUntouchedWhenValidationFails() async throws {
    let fixture = try CodexSwitchFixture()
    defer { fixture.remove() }
    let selectedCredential = makeCodexAuthData(accountID: "acct_selected", version: 1)
    let originalCredential = makeCodexAuthData(accountID: "acct_original", version: 1)
    try originalCredential.write(to: fixture.authURL)
    let validator = ClosureCodexValidator { _ in throw CodexSwitchTestError.validationFailed }
    let transaction = CodexAuthSwitchTransaction(globalStore: fixture.store, validator: validator)

    do {
        _ = try await transaction.execute(
            account: makeSwitchAccount(accountID: "acct_selected", credential: selectedCredential),
            authData: selectedCredential
        )
        Issue.record("Expected validation failure")
    } catch CodexSwitchTestError.validationFailed {
        // Expected.
    }

    #expect(try Data(contentsOf: fixture.authURL) == originalCredential)
}

@Test func codexSwitchRejectsValidatedCredentialForAnotherAccount() async throws {
    let fixture = try CodexSwitchFixture()
    defer { fixture.remove() }
    let selectedCredential = makeCodexAuthData(accountID: "acct_selected", version: 1)
    let wrongCredential = makeCodexAuthData(accountID: "acct_other", version: 2)
    let originalCredential = makeCodexAuthData(accountID: "acct_original", version: 1)
    try originalCredential.write(to: fixture.authURL)
    let validator = ClosureCodexValidator { _ in
        makeValidationResult(authData: wrongCredential, accountID: "acct_other")
    }
    let transaction = CodexAuthSwitchTransaction(globalStore: fixture.store, validator: validator)

    do {
        _ = try await transaction.execute(
            account: makeSwitchAccount(accountID: "acct_selected", credential: selectedCredential),
            authData: selectedCredential
        )
        Issue.record("Expected identity mismatch")
    } catch CodexAuthSwitchTransactionError.identityMismatch {
        // Expected.
    }

    #expect(try Data(contentsOf: fixture.authURL) == originalCredential)
}

@Test func codexSwitchPreservesExternalAuthMutationDetectedAfterValidation() async throws {
    let fixture = try CodexSwitchFixture()
    defer { fixture.remove() }
    let selectedCredential = makeCodexAuthData(accountID: "acct_selected", version: 1)
    let refreshedCredential = makeCodexAuthData(accountID: "acct_selected", version: 2)
    let originalCredential = makeCodexAuthData(accountID: "acct_original", version: 1)
    let externalCredential = makeCodexAuthData(accountID: "acct_external", version: 1)
    try originalCredential.write(to: fixture.authURL)
    let validator = ClosureCodexValidator { _ in
        try externalCredential.write(to: fixture.authURL, options: .atomic)
        return makeValidationResult(authData: refreshedCredential, accountID: "acct_selected")
    }
    let transaction = CodexAuthSwitchTransaction(globalStore: fixture.store, validator: validator)

    do {
        _ = try await transaction.execute(
            account: makeSwitchAccount(accountID: "acct_selected", credential: selectedCredential),
            authData: selectedCredential
        )
        Issue.record("Expected concurrent mutation failure")
    } catch GlobalCodexAuthServiceError.concurrentModification {
        // Expected.
    }

    #expect(try Data(contentsOf: fixture.authURL) == externalCredential)
}

@Test func codexSwitchRollsBackWhenCommittedAuthCannotBeVerified() async throws {
    let originalCredential = makeCodexAuthData(accountID: "acct_original", version: 1)
    let selectedCredential = makeCodexAuthData(accountID: "acct_selected", version: 1)
    let refreshedCredential = makeCodexAuthData(accountID: "acct_selected", version: 2)
    let store = VerificationFailingCodexStore(original: originalCredential)
    let validator = ClosureCodexValidator { _ in
        makeValidationResult(authData: refreshedCredential, accountID: "acct_selected")
    }
    let transaction = CodexAuthSwitchTransaction(globalStore: store, validator: validator)

    do {
        _ = try await transaction.execute(
            account: makeSwitchAccount(accountID: "acct_selected", credential: selectedCredential),
            authData: selectedCredential
        )
        Issue.record("Expected verification failure")
    } catch CodexSwitchTestError.verificationFailed {
        // Expected.
    }

    #expect(store.currentData == originalCredential)
    #expect(store.restoreCount == 1)
}

@Test func codexSwitchRemainsValidWhenOnlyRateLimitsAreUnavailable() async throws {
    let fixture = try CodexSwitchFixture()
    defer { fixture.remove() }
    let original = makeCodexAuthData(accountID: "acct_original", version: 1)
    let selected = makeCodexAuthData(accountID: "acct_selected", version: 1)
    try original.write(to: fixture.authURL)
    let validator = ClosureCodexValidator { _ in
        AccountValidationResult(
            authData: selected,
            authFingerprint: CodexAuthBlob.fingerprint(for: selected),
            identity: AuthIdentity(authMode: "chatgpt", accountId: "acct_selected", email: "selected@example.com"),
            email: "selected@example.com",
            planType: "pro",
            rateLimit: nil,
            rateLimitsByLimitId: nil,
            rateLimitError: "rate-limit endpoint unavailable"
        )
    }
    let transaction = CodexAuthSwitchTransaction(globalStore: fixture.store, validator: validator)

    let result = try await transaction.execute(
        account: makeSwitchAccount(accountID: "acct_selected", credential: selected),
        authData: selected
    )

    #expect(result.rateLimit == nil)
    #expect(result.rateLimitError == "rate-limit endpoint unavailable")
    #expect(try Data(contentsOf: fixture.authURL) == selected)
}

private struct ClosureCodexValidator: CodexAccountValidating {
    let operation: @Sendable (Data) async throws -> AccountValidationResult

    init(operation: @escaping @Sendable (Data) async throws -> AccountValidationResult) {
        self.operation = operation
    }

    func validate(authData: Data) async throws -> AccountValidationResult {
        try await operation(authData)
    }
}

private final class VerificationFailingCodexStore: GlobalCodexAuthStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private(set) var restoreCount = 0

    init(original: Data) {
        data = original
    }

    var currentData: Data? {
        lock.withLock { data }
    }

    func readSnapshot() throws -> GlobalCodexAuthSnapshot {
        lock.withLock { GlobalCodexAuthSnapshot(data: data) }
    }

    func commit(expected: GlobalCodexAuthSnapshot, replacement: Data) throws {
        try lock.withLock {
            guard data == expected.data else {
                throw GlobalCodexAuthServiceError.concurrentModification
            }
            data = replacement
        }
    }

    func verifyCommitted(_ replacement: Data) throws {
        throw CodexSwitchTestError.verificationFailed
    }

    func restore(_ original: GlobalCodexAuthSnapshot, replacing replacement: Data) throws {
        try lock.withLock {
            guard data == replacement else {
                throw GlobalCodexAuthServiceError.concurrentModification
            }
            data = original.data
            restoreCount += 1
        }
    }
}

private struct CodexSwitchFixture {
    let root: URL
    let authURL: URL
    let store: GlobalCodexAuthService

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "limits-codex-switch-\(UUID().uuidString)", directoryHint: .isDirectory)
        authURL = root.appending(path: "auth.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = GlobalCodexAuthService(authURL: authURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum CodexSwitchTestError: Error {
    case validationFailed
    case verificationFailed
}

private actor PreparationRecorder {
    private(set) var wasPrepared = false

    func markPrepared() {
        wasPrepared = true
    }
}

private func makeSwitchAccount(accountID: String, credential: Data) -> StoredAccount {
    let id = UUID()
    return StoredAccount(
        id: id,
        label: accountID,
        email: "\(accountID)@example.com",
        accountId: accountID,
        planType: "pro",
        createdAt: .distantPast,
        updatedAt: .distantPast,
        lastValidatedAt: nil,
        status: .unknown,
        statusMessage: nil,
        authFingerprint: CodexAuthBlob.fingerprint(for: credential),
        keychainAccount: "account.\(id.uuidString)"
    )
}

private func makeValidationResult(authData: Data, accountID: String) -> AccountValidationResult {
    AccountValidationResult(
        authData: authData,
        authFingerprint: CodexAuthBlob.fingerprint(for: authData),
        identity: AuthIdentity(authMode: "chatgpt", accountId: accountID, email: "\(accountID)@example.com"),
        email: "\(accountID)@example.com",
        planType: "pro",
        rateLimit: nil,
        rateLimitsByLimitId: nil
    )
}

private func makeCodexAuthData(accountID: String, version: Int) -> Data {
    let tokenPayload = Data("{\"email\":\"\(accountID)@example.com\"}".utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return Data(
        "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"account_id\":\"\(accountID)\",\"id_token\":\"header.\(tokenPayload).signature\",\"version\":\(version)}}".utf8
    )
}

private func posixMode(at url: URL) -> Int {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
