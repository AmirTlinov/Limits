import Foundation
import Testing
@testable import LimitsCore

@Test func repeatedCodexRefreshesCoalesceIntoOneValidation() async throws {
    let auth = codexAuthData(accountID: "acct-a")
    let global = CoordinatorCodexGlobalStore(data: auth)
    let service = CoordinatorCodexService(delay: 80_000_000)
    let coordinator = CodexSessionCoordinator(globalStore: global, accountService: service)

    async let first = coordinator.refreshCurrent()
    async let second = coordinator.refreshCurrent()
    _ = try await (first, second)

    #expect(service.validationCount == 1)
}

@Test func codexProbeStartedBeforeSwitchCannotPublishAfterSwitchBegins() async throws {
    let oldAuth = codexAuthData(accountID: "acct-old")
    let targetAuth = codexAuthData(accountID: "acct-new")
    let global = CoordinatorCodexGlobalStore(data: oldAuth)
    let service = CoordinatorCodexService(delay: 120_000_000)
    let coordinator = CodexSessionCoordinator(globalStore: global, accountService: service)
    let target = coordinatorStoredAccount(accountID: "acct-new", authData: targetAuth)

    let refresh = Task { try await coordinator.refreshCurrent() }
    try await Task.sleep(nanoseconds: 20_000_000)
    let switched = Task { try await coordinator.switchAccount(target, authData: targetAuth) }

    let refreshOutcome = try await refresh.value
    _ = try await switched.value
    if case .published = refreshOutcome {
        Issue.record("A probe from the previous auth session was published after switching began.")
    }
    #expect(global.currentData == targetAuth)
}

@Test func claudeStatusProbePersistsCredentialRotationThroughRepository() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "limits-claude-coordinator-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let keychain = CoordinatorMemoryKeychain()
    let repository = AccountsRepository(
        persistence: AccountsPersistence(baseURL: root.appending(path: "state")),
        vault: KeychainAuthVault(store: keychain)
    )
    _ = try await repository.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)
    let original = Data("original-credential".utf8)
    let rotated = Data("rotated-credential".utf8)
    let account = coordinatorClaudeAccount(credential: original)
    _ = try await repository.saveClaudeAccount(account, credential: original)

    let global = CoordinatorClaudeGlobalStore(data: original)
    let status = ClaudeAuthStatus(
        loggedIn: true, authMethod: "claude.ai", apiProvider: nil,
        email: account.email, orgId: account.orgId, orgName: "Org", subscriptionType: "max"
    )
    let reader = CoordinatorClaudeStatusReader(status: status) {
        global.force(rotated)
    }
    let coordinator = ClaudeSessionCoordinator(
        globalStore: global,
        statusReader: reader,
        repository: repository,
        bridge: ClaudeStatuslineBridgeService(
            homeDirectory: root.appending(path: "home"),
            appSupportDirectory: root.appending(path: "bridge")
        )
    )

    let result = try await coordinator.probe()
    let stored = try #require(result.repositorySnapshot.state.claudeAccounts.first)
    #expect(stored.authFingerprint == CodexAuthBlob.fingerprint(for: rotated))
    #expect(try await repository.credential(provider: .claude, accountID: stored.id) == rotated)
}

@Test func claudeRepositoryFailureKeepsLiveStableIdentityVisibleAndGlobalRotationIntact() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "limits-claude-repository-error-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let keychain = CoordinatorMemoryKeychain()
    let fault = CoordinatorRepositoryFault()
    let repository = AccountsRepository(
        persistence: AccountsPersistence(baseURL: root.appending(path: "state")),
        vault: KeychainAuthVault(store: keychain),
        faultInjector: { try fault.check($0) }
    )
    _ = try await repository.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)
    let original = Data("original-credential".utf8)
    let rotated = Data("rotated-credential".utf8)
    let account = coordinatorClaudeAccount(credential: original)
    _ = try await repository.saveClaudeAccount(account, credential: original)
    fault.arm()

    let global = CoordinatorClaudeGlobalStore(data: original)
    let status = loggedInClaudeStatus(email: account.email, orgID: account.orgId!)
    let reader = CoordinatorClaudeStatusReader(status: status) { global.force(rotated) }
    let coordinator = ClaudeSessionCoordinator(
        globalStore: global,
        statusReader: reader,
        repository: repository,
        bridge: ClaudeStatuslineBridgeService(
            homeDirectory: root.appending(path: "home"),
            appSupportDirectory: root.appending(path: "bridge")
        )
    )

    let result = try await coordinator.probe()
    #expect(result.source == .stored(account.id))
    #expect(result.repositoryError != nil)
    #expect(global.currentData == rotated)
    #expect(ProviderCatalogSnapshot(savedClaudeCount: 1, claudeSource: result.source).providers == [.codex, .claude])
}

@Test func claudeDiscoveryDoesNotTreatInstallationOrBridgeAsAnAccount() async throws {
    let fixture = try await ClaudeCoordinatorFixture()
    try fixture.bridge.installBridge()
    try Data("{\"five_hour\":{\"used_percentage\":10}}".utf8).write(to: fixture.bridge.snapshotURL)
    fixture.reader.set(statuses: [loggedOutClaudeStatus])

    let result = try await fixture.coordinator.probe()
    let catalog = ProviderCatalogSnapshot(
        savedClaudeCount: result.repositorySnapshot.state.claudeAccounts.count,
        claudeSource: result.source
    )

    #expect(result.source == .loggedOut)
    #expect(result.bridgeStatus.installed)
    #expect(result.evidence == nil)
    #expect(catalog.providers == [.codex])
    #expect(!FileManager.default.fileExists(atPath: fixture.bridge.snapshotURL.path))
    await fixture.remove()
}

@Test func missingClaudeCLIWithoutSavedAccountsKeepsCatalogCodexOnly() async throws {
    let fixture = try await ClaudeCoordinatorFixture()
    fixture.reader.setInstalled(false)

    let result = try await fixture.coordinator.probe()
    #expect(result.source == .notInstalled)
    #expect(ProviderCatalogSnapshot(savedClaudeCount: 0, claudeSource: result.source).providers == [.codex])
    await fixture.remove()
}

@Test func liveClaudeIdentityAppearsWhileSavedLoggedOutIdentityRemainsRecoverable() async throws {
    let fixture = try await ClaudeCoordinatorFixture()
    let live = loggedInClaudeStatus(email: "user@example.com", orgID: "org-live")
    fixture.reader.set(statuses: [live])

    let external = try await fixture.coordinator.probe()
    #expect(external.source == .external("user@example.com"))
    #expect(ProviderCatalogSnapshot(savedClaudeCount: 0, claudeSource: external.source).providers == [.codex, .claude])

    let credential = Data("saved-credential".utf8)
    let saved = coordinatorClaudeAccount(credential: credential)
    _ = try await fixture.repository.saveClaudeAccount(saved, credential: credential)
    fixture.reader.set(statuses: [loggedOutClaudeStatus])

    let loggedOut = try await fixture.coordinator.probe()
    #expect(loggedOut.source == .loggedOut)
    #expect(loggedOut.repositorySnapshot.state.claudeAccounts.count == 1)
    #expect(ProviderCatalogSnapshot(savedClaudeCount: 1, claudeSource: loggedOut.source).providers == [.codex, .claude])
    await fixture.remove()
}

@Test func claudeEvidenceRequiresOneIdentityOnBothSidesAndClearsOnLogout() async throws {
    let fixture = try await ClaudeCoordinatorFixture()
    try fixture.bridge.installBridge()
    let firstIdentity = loggedInClaudeStatus(email: "user@example.com", orgID: "org-a")
    let secondIdentity = loggedInClaudeStatus(email: "user@example.com", orgID: "org-b")
    fixture.reader.set(statuses: [firstIdentity])
    _ = try await fixture.coordinator.probe(now: Date())

    try Data("{\"five_hour\":{\"used_percentage\":25,\"resets_at\":4102444800}}".utf8)
        .write(to: fixture.bridge.snapshotURL, options: .atomic)
    fixture.reader.set(statuses: [firstIdentity, secondIdentity])
    let changedDuringRead = try await fixture.coordinator.probe(now: Date())
    #expect(changedDuringRead.evidence == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.bridge.snapshotURL.path))

    fixture.reader.set(statuses: [firstIdentity])
    _ = try await fixture.coordinator.probe(now: Date())
    try Data("{\"five_hour\":{\"used_percentage\":25,\"resets_at\":4102444800}}".utf8)
        .write(to: fixture.bridge.snapshotURL, options: .atomic)
    fixture.reader.set(statuses: [firstIdentity, firstIdentity])
    let accepted = try await fixture.coordinator.probe(now: Date())
    #expect(accepted.evidence?.identity.organizationId == "org-a")

    fixture.reader.set(statuses: [loggedOutClaudeStatus])
    let loggedOut = try await fixture.coordinator.probe(now: Date())
    #expect(loggedOut.source == .loggedOut)
    #expect(loggedOut.evidence == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.bridge.snapshotURL.path))
    await fixture.remove()
}

@Test func unreadableClaudeProbeWithoutSavedAccountsCannotCreatePresence() async throws {
    let fixture = try await ClaudeCoordinatorFixture()
    fixture.reader.failNextRead()

    await #expect(throws: CoordinatorStatusFailure.self) {
        try await fixture.coordinator.probe()
    }
    #expect(ProviderCatalogSnapshot(savedClaudeCount: 0, claudeSource: .unreadable).providers == [.codex])
    await fixture.remove()
}

private final class CoordinatorCodexGlobalStore: GlobalCodexAuthStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    init(data: Data?) { self.data = data }
    var currentData: Data? { lock.withLock { data } }
    func readSnapshot() -> GlobalCodexAuthSnapshot { lock.withLock { GlobalCodexAuthSnapshot(data: data) } }
    func commit(expected: GlobalCodexAuthSnapshot, replacement: Data) throws {
        try lock.withLock {
            guard data == expected.data else { throw GlobalCodexAuthServiceError.concurrentModification }
            data = replacement
        }
    }
    func verifyCommitted(_ replacement: Data) throws {
        try lock.withLock { if data != replacement { throw GlobalCodexAuthServiceError.committedDataMismatch } }
    }
    func restore(_ original: GlobalCodexAuthSnapshot, replacing replacement: Data) throws {
        try lock.withLock {
            guard data == replacement else { throw GlobalCodexAuthServiceError.concurrentModification }
            data = original.data
        }
    }
}

private final class CoordinatorCodexService: CodexLoginServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let delay: UInt64
    init(delay: UInt64) { self.delay = delay }
    var validationCount: Int { lock.withLock { count } }
    func validate(authData: Data) async throws -> AccountValidationResult {
        lock.withLock { count += 1 }
        try await Task.sleep(nanoseconds: delay)
        let identity = try CodexAuthBlob.identity(from: authData)
        return AccountValidationResult(
            authData: authData,
            authFingerprint: CodexAuthBlob.fingerprint(for: authData),
            identity: identity,
            email: "\(identity.accountId ?? "account")@example.com",
            planType: "pro",
            rateLimit: nil,
            rateLimitsByLimitId: nil
        )
    }
    func loginNewAccount(openURL: @MainActor @escaping @Sendable (URL) -> Void) async throws -> AccountValidationResult {
        throw CancellationError()
    }
}

private final class CoordinatorClaudeGlobalStore: GlobalClaudeCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    init(data: Data?) { self.data = data }
    var currentData: Data? { lock.withLock { data } }
    func force(_ value: Data?) { lock.withLock { data = value } }
    func readSnapshot() -> GlobalClaudeCredentialSnapshot {
        lock.withLock { GlobalClaudeCredentialSnapshot(account: "user", data: data) }
    }
    func commit(expected: GlobalClaudeCredentialSnapshot, replacement: Data) throws { force(replacement) }
    func verifyCommitted(_ replacement: Data, basedOn original: GlobalClaudeCredentialSnapshot) throws {
        if readSnapshot().data != replacement { throw GlobalClaudeCredentialServiceError.committedDataMismatch }
    }
    func restore(_ original: GlobalClaudeCredentialSnapshot, replacing replacement: Data) throws { force(original.data) }
}

private final class CoordinatorClaudeStatusReader: ClaudeSessionStatusReading, @unchecked Sendable {
    private let lock = NSLock()
    private let status: ClaudeAuthStatus
    private let firstRead: @Sendable () -> Void
    private var didRead = false
    init(status: ClaudeAuthStatus, firstRead: @escaping @Sendable () -> Void) {
        self.status = status
        self.firstRead = firstRead
    }
    func isInstalled() -> Bool { true }
    func readStatus() async throws -> ClaudeAuthStatus {
        let shouldRotate = lock.withLock { () -> Bool in
            defer { didRead = true }
            return !didRead
        }
        if shouldRotate { firstRead() }
        return status
    }
}

private struct CoordinatorStatusFailure: Error {}
private struct CoordinatorRepositoryFailure: Error {}

private final class CoordinatorRepositoryFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    func arm() { lock.withLock { armed = true } }
    func check(_ checkpoint: AccountsRepositoryCheckpoint) throws {
        if lock.withLock({ armed && checkpoint == .beforeStateWrite }) {
            throw CoordinatorRepositoryFailure()
        }
    }
}

private final class MutableClaudeStatusReader: ClaudeSessionStatusReading, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [ClaudeAuthStatus]
    private var shouldFail = false
    private var installed = true

    init(status: ClaudeAuthStatus = loggedOutClaudeStatus) {
        statuses = [status]
    }

    func isInstalled() -> Bool { lock.withLock { installed } }

    func setInstalled(_ installed: Bool) {
        lock.withLock { self.installed = installed }
    }

    func set(statuses: [ClaudeAuthStatus]) {
        lock.withLock {
            self.statuses = statuses
            shouldFail = false
        }
    }

    func failNextRead() {
        lock.withLock { shouldFail = true }
    }

    func readStatus() async throws -> ClaudeAuthStatus {
        try lock.withLock {
            if shouldFail {
                shouldFail = false
                throw CoordinatorStatusFailure()
            }
            let status = statuses.first ?? loggedOutClaudeStatus
            if statuses.count > 1 { statuses.removeFirst() }
            return status
        }
    }
}

private final class ClaudeCoordinatorFixture: @unchecked Sendable {
    let root: URL
    let reader: MutableClaudeStatusReader
    let repository: AccountsRepository
    let bridge: ClaudeStatuslineBridgeService
    let coordinator: ClaudeSessionCoordinator

    init() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "limits-claude-fixture-\(UUID().uuidString)")
        reader = MutableClaudeStatusReader()
        repository = AccountsRepository(
            persistence: AccountsPersistence(baseURL: root.appending(path: "state")),
            vault: KeychainAuthVault(store: CoordinatorMemoryKeychain())
        )
        bridge = ClaudeStatuslineBridgeService(
            homeDirectory: root.appending(path: "home"),
            appSupportDirectory: root.appending(path: "bridge")
        )
        coordinator = ClaudeSessionCoordinator(
            globalStore: CoordinatorClaudeGlobalStore(data: nil),
            statusReader: reader,
            repository: repository,
            bridge: bridge
        )
        _ = try await repository.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)
    }

    func remove() async {
        await repository.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private let loggedOutClaudeStatus = ClaudeAuthStatus(
    loggedIn: false,
    authMethod: nil,
    apiProvider: nil,
    email: nil,
    orgId: nil,
    orgName: nil,
    subscriptionType: nil
)

private func loggedInClaudeStatus(email: String, orgID: String) -> ClaudeAuthStatus {
    ClaudeAuthStatus(
        loggedIn: true,
        authMethod: "claude.ai",
        apiProvider: nil,
        email: email,
        orgId: orgID,
        orgName: orgID,
        subscriptionType: "max"
    )
}

private final class CoordinatorMemoryKeychain: KeychainAuthDataStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func save(_ data: Data, account: String, label: String) { lock.withLock { values[account] = data } }
    func read(account: String) throws -> Data {
        try lock.withLock {
            guard let value = values[account] else { throw KeychainAuthVaultError.missingEntry }
            return value
        }
    }
    func delete(account: String) { lock.withLock { _ = values.removeValue(forKey: account) } }
}

private func codexAuthData(accountID: String) -> Data {
    Data("{\"auth_mode\":\"chatgpt\",\"tokens\":{\"account_id\":\"\(accountID)\"}}".utf8)
}

private func coordinatorStoredAccount(accountID: String, authData: Data) -> StoredAccount {
    StoredAccount(
        id: UUID(), label: accountID, email: "\(accountID)@example.com", accountId: accountID,
        planType: "pro", createdAt: .distantPast, updatedAt: .distantPast, lastValidatedAt: nil,
        status: .ok, statusMessage: nil, authFingerprint: CodexAuthBlob.fingerprint(for: authData), keychainAccount: "unused"
    )
}

private func coordinatorClaudeAccount(credential: Data) -> ClaudeStoredAccount {
    let id = UUID()
    return ClaudeStoredAccount(
        id: id, label: "Claude", email: "user@example.com", subscriptionType: "max", authMethod: "claude.ai",
        orgId: "org-a", orgName: "Org", createdAt: .distantPast, updatedAt: .distantPast,
        lastValidatedAt: nil, status: .ok, statusMessage: nil,
        authFingerprint: CodexAuthBlob.fingerprint(for: credential), keychainAccount: "claude.\(id.uuidString)"
    )
}

@Test func claudeProbeKeepsAnAgedSnapshotSoSurfacesCanStillShowIt() async throws {
    let fixture = try await ClaudeCoordinatorFixture()
    defer { Task { await fixture.remove() } }

    let account = coordinatorClaudeAccount(credential: Data("credential".utf8))
    fixture.reader.set(statuses: [loggedInClaudeStatus(email: account.email, orgID: account.orgId!)])
    try fixture.bridge.installBridge()

    let snapshot = #"{"five_hour":{"used_percentage":41,"resets_at":4000000000}}"#
    try Data(snapshot.utf8).write(to: fixture.bridge.snapshotURL, options: .atomic)

    // The bridge only writes while a Claude Code session runs, so a reading this old is the
    // normal state between sessions, not a fault.
    let aged = Date().addingTimeInterval(-6 * 60 * 60)
    try FileManager.default.setAttributes(
        [.modificationDate: aged],
        ofItemAtPath: fixture.bridge.snapshotURL.path
    )

    let result = try await fixture.coordinator.probe()
    let evidence = try #require(result.evidence)
    #expect(evidence.snapshot.fiveHour?.usedPercentage == 41)
    #expect(evidence.snapshotAt < Date().addingTimeInterval(-60 * 60))
    #expect(result.bridgeUpgradeError == nil)

    // Surfaces that require a current reading still reject it on their own.
    #expect(ClaudeLivePresentation.rateLimitSections(evidence: evidence).isEmpty)
    #expect(!ClaudeLivePresentation.lastKnownRateLimitSections(evidence: evidence).isEmpty)
}
