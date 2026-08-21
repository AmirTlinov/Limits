import Foundation
import Testing
@testable import LimitsCore

@Test func usageCoordinatorAppliesTieredTTLsAndCoalescesEndpointWork() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "limits-usage-coordinator-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let usage = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    let keychain = CoordinatorMemoryKeychain()
    let accounts = AccountsRepository(
        persistence: AccountsPersistence(baseURL: root),
        usageRepository: usage,
        vault: KeychainAuthVault(store: keychain)
    )
    _ = try await accounts.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)
    let source = coordinatorAccount()
    let saved = try await accounts.saveCodexAccount(source, credential: Data("credential".utf8))
    let account = try #require(saved.state.accounts.first)
    let service = CoordinatorProbeService(accountID: "acct_coordinator", email: account.email)
    let session = CodexSessionCoordinator(globalStore: CoordinatorGlobalStore(), accountService: service)
    let coordinator = CodexUsageCoordinator(
        accountsRepository: accounts,
        usageRepository: usage,
        sessionCoordinator: session,
        codexHome: nil,
        pricingDownloader: CoordinatorOfflinePricing()
    )
    let start = Date(timeIntervalSince1970: 2_000_000)

    _ = try await coordinator.refresh(currentAccountLocalID: nil, selectedAccountLocalID: account.id, now: start)
    _ = try await coordinator.refresh(currentAccountLocalID: nil, selectedAccountLocalID: account.id, now: start.addingTimeInterval(60))
    _ = try await coordinator.refresh(currentAccountLocalID: nil, selectedAccountLocalID: account.id, now: start.addingTimeInterval(16 * 60))
    _ = try await coordinator.refresh(currentAccountLocalID: nil, selectedAccountLocalID: account.id, now: start.addingTimeInterval(61 * 60))

    let requests = await service.requests
    #expect(requests == [.all, .limits, .all])
    let snapshot = try await usage.snapshot()
    #expect(snapshot.endpointStatuses["acct_coordinator"]?[.limits]?.successfulAt == start.addingTimeInterval(61 * 60))
    #expect(snapshot.endpointStatuses["acct_coordinator"]?[.usage]?.successfulAt == start.addingTimeInterval(61 * 60))
    #expect(snapshot.limitObservations["acct_coordinator"]?.count == 6)
    #expect(try await usage.accountID(at: start.addingTimeInterval(1)) == nil)
}

@Test func endpointFailureKeepsAccountSwitchableAndBacksOffWithoutLosingLastUsage() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "limits-usage-backoff-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let usage = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    let accounts = AccountsRepository(
        persistence: AccountsPersistence(baseURL: root),
        usageRepository: usage,
        vault: KeychainAuthVault(store: CoordinatorMemoryKeychain())
    )
    _ = try await accounts.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)
    let saved = try await accounts.saveCodexAccount(coordinatorAccount(), credential: Data("credential".utf8))
    let account = try #require(saved.state.accounts.first)
    let service = CoordinatorProbeService(accountID: "acct_coordinator", email: account.email)
    let coordinator = CodexUsageCoordinator(
        accountsRepository: accounts,
        usageRepository: usage,
        sessionCoordinator: CodexSessionCoordinator(globalStore: CoordinatorGlobalStore(), accountService: service),
        codexHome: nil,
        pricingDownloader: CoordinatorOfflinePricing()
    )
    let start = Date(timeIntervalSince1970: 2_000_000)
    _ = try await coordinator.refresh(currentAccountLocalID: nil, selectedAccountLocalID: account.id, now: start)
    await service.setFailLimits(true)
    _ = try await coordinator.refresh(
        currentAccountLocalID: nil,
        selectedAccountLocalID: account.id,
        forceAccountIDs: [account.id],
        now: start.addingTimeInterval(60)
    )
    _ = try await coordinator.refresh(currentAccountLocalID: nil, selectedAccountLocalID: account.id, now: start.addingTimeInterval(120))

    let stored = try await accounts.reload().state.accounts.first
    let snapshot = try await usage.snapshot()
    #expect(stored?.status == .ok)
    #expect(snapshot.latestLimits["acct_coordinator"]?.primary != nil)
    #expect(snapshot.endpointStatuses["acct_coordinator"]?[.limits]?.errorMessage == "limits unavailable")
    #expect(await service.requests.count == 2)
}

@Test func strongerRefreshIntentRunsAfterTheActiveCoalescedRefresh() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "limits-usage-intent-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let usage = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root))
    let accounts = AccountsRepository(
        persistence: AccountsPersistence(baseURL: root),
        usageRepository: usage,
        vault: KeychainAuthVault(store: CoordinatorMemoryKeychain())
    )
    _ = try await accounts.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)
    let firstSaved = try await accounts.saveCodexAccount(
        coordinatorAccount(accountID: "acct_a", email: "a@example.com", label: "A"),
        credential: Data("acct_a".utf8)
    )
    let first = try #require(firstSaved.state.accounts.first { $0.accountId == "acct_a" })
    let secondSaved = try await accounts.saveCodexAccount(
        coordinatorAccount(accountID: "acct_b", email: "b@example.com", label: "B"),
        credential: Data("acct_b".utf8)
    )
    let second = try #require(secondSaved.state.accounts.first { $0.accountId == "acct_b" })
    let gate = CoordinatorFirstProbeGate()
    let service = CoordinatorCredentialProbeService(gate: gate)
    let coordinator = CodexUsageCoordinator(
        accountsRepository: accounts,
        usageRepository: usage,
        sessionCoordinator: CodexSessionCoordinator(globalStore: CoordinatorGlobalStore(), accountService: service),
        codexHome: nil,
        pricingDownloader: CoordinatorOfflinePricing()
    )
    let start = Date(timeIntervalSince1970: 3_000_000)

    let active = Task {
        try await coordinator.refresh(
            currentAccountLocalID: nil,
            selectedAccountLocalID: first.id,
            now: start
        )
    }
    await gate.waitUntilStarted()
    let stronger = Task {
        try await coordinator.refresh(
            currentAccountLocalID: nil,
            selectedAccountLocalID: second.id,
            forceAccountIDs: [second.id],
            now: start.addingTimeInterval(1)
        )
    }
    await gate.release()
    _ = try await active.value
    _ = try await stronger.value

    #expect(await service.accountRequests == ["acct_a", "acct_b", "acct_b"])
    await usage.close()
}

@Test func clearingStatisticsSkipsOldRolloutBytesUntilExplicitReimport() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "limits-usage-clear-import-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let codexHome = root.appending(path: "Codex", directoryHint: .isDirectory)
    let archive = codexHome.appending(path: "archived_sessions", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    try coordinatorRolloutFixture.write(
        to: archive.appending(path: "completed.jsonl"),
        atomically: true,
        encoding: .utf8
    )
    let usage = CodexUsageRepository(persistence: CodexUsagePersistence(baseURL: root.appending(path: "Data")))
    let accounts = AccountsRepository(
        persistence: AccountsPersistence(baseURL: root.appending(path: "Data")),
        usageRepository: usage,
        vault: KeychainAuthVault(store: CoordinatorMemoryKeychain())
    )
    _ = try await accounts.open(currentCodexFingerprint: nil, currentClaudeFingerprint: nil)
    let coordinator = CodexUsageCoordinator(
        accountsRepository: accounts,
        usageRepository: usage,
        sessionCoordinator: CodexSessionCoordinator(globalStore: CoordinatorGlobalStore(), accountService: CoordinatorCredentialProbeService()),
        codexHome: codexHome,
        allowsServerProbes: false,
        pricingDownloader: CoordinatorOfflinePricing()
    )

    #expect(try await coordinator.reimportHistory().dailyUsage.reduce(0) { $0 + $1.usage.totalTokens } == 12)
    #expect(try await coordinator.clearStatistics().dailyUsage.isEmpty)
    let regular = try await coordinator.refresh(currentAccountLocalID: nil, selectedAccountLocalID: nil)
    #expect(regular.usage.dailyUsage.isEmpty)
    #expect(try await coordinator.reimportHistory().dailyUsage.reduce(0) { $0 + $1.usage.totalTokens } == 12)
    await usage.close()
}

private actor CoordinatorProbeService: CodexLoginServicing {
    let accountID: String
    let email: String
    var requests: [CodexAccountProbeRequest] = []
    var failLimits = false

    init(accountID: String, email: String) {
        self.accountID = accountID
        self.email = email
    }

    func setFailLimits(_ value: Bool) { failLimits = value }

    func validate(authData: Data) async throws -> AccountValidationResult {
        try await validate(authData: authData, request: .all)
    }

    func validate(authData: Data, request: CodexAccountProbeRequest) async throws -> AccountValidationResult {
        requests.append(request)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let limit = RateLimitSnapshotModel(
            credits: nil,
            limitId: "codex",
            limitName: nil,
            planType: "pro",
            primary: RateLimitWindowSnapshot(
                resetsAt: Int64(now.addingTimeInterval(7 * 24 * 60 * 60).timeIntervalSince1970),
                usedPercent: 20 + requests.count,
                windowDurationMins: 300
            ),
            rateLimitReachedType: nil,
            secondary: RateLimitWindowSnapshot(
                resetsAt: Int64(now.addingTimeInterval(7 * 24 * 60 * 60).timeIntervalSince1970),
                usedPercent: 30 + requests.count,
                windowDurationMins: 10_080
            )
        )
        return AccountValidationResult(
            authData: authData,
            authFingerprint: CodexAuthBlob.fingerprint(for: authData),
            identity: AuthIdentity(authMode: "chatgpt", accountId: accountID, email: email),
            email: email,
            planType: "pro",
            rateLimit: request.rateLimits && !failLimits ? limit : nil,
            rateLimitsByLimitId: request.rateLimits && !failLimits ? ["codex": limit] : nil,
            rateLimitError: request.rateLimits && failLimits ? "limits unavailable" : nil,
            didRequestRateLimits: request.rateLimits,
            accountUsage: request.accountUsage ? CodexAccountUsageSnapshot(
                accountID: accountID,
                observedAt: now,
                summary: CodexAccountUsageSummary(
                    lifetimeTokens: 10_000,
                    peakDailyTokens: 1_000,
                    longestRunningTurnSeconds: nil,
                    currentStreakDays: nil,
                    longestStreakDays: nil
                ),
                dailyActivity: [CodexDailyTokenActivity(date: now, tokens: 1_000)]
            ) : nil,
            accountUsageError: nil,
            didRequestAccountUsage: request.accountUsage
        )
    }

    func loginNewAccount(openURL: @MainActor @escaping @Sendable (URL) -> Void) async throws -> AccountValidationResult {
        throw CancellationError()
    }
}

private actor CoordinatorFirstProbeGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pauseFirst() async {
        guard !started else { return }
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor CoordinatorCredentialProbeService: CodexLoginServicing {
    private let gate: CoordinatorFirstProbeGate?
    private(set) var accountRequests: [String] = []

    init(gate: CoordinatorFirstProbeGate? = nil) {
        self.gate = gate
    }

    func validate(authData: Data) async throws -> AccountValidationResult {
        try await validate(authData: authData, request: .all)
    }

    func validate(authData: Data, request: CodexAccountProbeRequest) async throws -> AccountValidationResult {
        let accountID = String(decoding: authData, as: UTF8.self)
        accountRequests.append(accountID)
        if let gate { await gate.pauseFirst() }
        let now = Date(timeIntervalSince1970: 3_000_000)
        let limit = RateLimitSnapshotModel(
            credits: nil,
            limitId: "codex",
            limitName: nil,
            planType: "pro",
            primary: RateLimitWindowSnapshot(
                resetsAt: Int64(now.addingTimeInterval(300).timeIntervalSince1970),
                usedPercent: 10,
                windowDurationMins: 300
            ),
            rateLimitReachedType: nil,
            secondary: RateLimitWindowSnapshot(
                resetsAt: Int64(now.addingTimeInterval(10_080 * 60).timeIntervalSince1970),
                usedPercent: 20,
                windowDurationMins: 10_080
            )
        )
        return AccountValidationResult(
            authData: authData,
            authFingerprint: CodexAuthBlob.fingerprint(for: authData),
            identity: AuthIdentity(authMode: "chatgpt", accountId: accountID, email: "\(accountID)@example.com"),
            email: "\(accountID)@example.com",
            planType: "pro",
            rateLimit: request.rateLimits ? limit : nil,
            rateLimitsByLimitId: request.rateLimits ? ["codex": limit] : nil,
            rateLimitError: nil,
            didRequestRateLimits: request.rateLimits,
            accountUsage: request.accountUsage ? CodexAccountUsageSnapshot(
                accountID: accountID,
                observedAt: now,
                summary: CodexAccountUsageSummary(
                    lifetimeTokens: 100,
                    peakDailyTokens: 100,
                    longestRunningTurnSeconds: nil,
                    currentStreakDays: nil,
                    longestStreakDays: nil
                ),
                dailyActivity: []
            ) : nil,
            accountUsageError: nil,
            didRequestAccountUsage: request.accountUsage
        )
    }

    func loginNewAccount(openURL: @MainActor @escaping @Sendable (URL) -> Void) async throws -> AccountValidationResult {
        throw CancellationError()
    }
}

private final class CoordinatorMemoryKeychain: KeychainAuthDataStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func save(_ data: Data, account: String, label: String) { lock.withLock { values[account] = data } }
    func read(account: String) throws -> Data {
        try lock.withLock { guard let data = values[account] else { throw KeychainAuthVaultError.missingEntry }; return data }
    }
    func delete(account: String) { lock.withLock { _ = values.removeValue(forKey: account) } }
}

private struct CoordinatorGlobalStore: GlobalCodexAuthStoring {
    func readSnapshot() throws -> GlobalCodexAuthSnapshot { GlobalCodexAuthSnapshot(data: nil) }
    func commit(expected: GlobalCodexAuthSnapshot, replacement: Data) throws {}
    func verifyCommitted(_ replacement: Data) throws {}
    func restore(_ original: GlobalCodexAuthSnapshot, replacing replacement: Data) throws {}
}

private struct CoordinatorOfflinePricing: OpenAIPricingDownloading {
    func download(_ url: URL) async throws -> OpenAIPricingDownload { throw URLError(.notConnectedToInternet) }
}

private func coordinatorAccount(
    accountID: String = "acct_coordinator",
    email: String = "coordinator@example.com",
    label: String = "Coordinator"
) -> StoredAccount {
    StoredAccount(
        id: UUID(),
        label: label,
        email: email,
        accountId: accountID,
        planType: "pro",
        createdAt: .distantPast,
        updatedAt: .distantPast,
        lastValidatedAt: nil,
        status: .ok,
        statusMessage: nil,
        authFingerprint: "",
        keychainAccount: ""
    )
}

private let coordinatorRolloutFixture = """
{"timestamp":"2026-08-21T00:00:00Z","type":"session_meta","payload":{"id":"thread-clear"}}
{"timestamp":"2026-08-21T00:01:00Z","type":"turn_context","payload":{"turn_id":"turn-clear","model":"gpt-5.6-sol"}}
{"timestamp":"2026-08-21T00:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":2,"reasoning_output_tokens":1,"total_tokens":12}}}}
{"timestamp":"2026-08-21T00:03:00Z","type":"event_msg","payload":{"type":"task_complete"}}
""" + "\n"
