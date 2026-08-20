import Foundation
import LimitsCore
import LimitsShared

struct LimitsRuntimeEnvironment {
    let isolatedRoot: URL?
    let disablesExternalProbes: Bool
    let isUITest: Bool

    static var current: LimitsRuntimeEnvironment {
        let environment = ProcessInfo.processInfo.environment
        let root = environment["LIMITS_TEST_ROOT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        return LimitsRuntimeEnvironment(
            isolatedRoot: root,
            disablesExternalProbes: environment["LIMITS_DISABLE_EXTERNAL_PROBES"] == "1",
            isUITest: environment["LIMITS_UI_TEST"] == "1"
        )
    }
}

private final class RuntimeMemoryKeychainStore: KeychainAuthDataStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func save(_ data: Data, account: String, label: String) {
        lock.withLock { values[account] = data }
    }

    func read(account: String) throws -> Data {
        try lock.withLock {
            guard let data = values[account] else { throw KeychainAuthVaultError.missingEntry }
            return data
        }
    }

    func delete(account: String) {
        lock.withLock { values.removeValue(forKey: account) }
    }
}

final class RuntimeClaudeCredentialStore: GlobalClaudeCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = GlobalClaudeCredentialSnapshot(account: nil, data: nil)

    func readSnapshot() -> GlobalClaudeCredentialSnapshot { lock.withLock { snapshot } }
    func commit(expected: GlobalClaudeCredentialSnapshot, replacement: Data) throws {
        try lock.withLock {
            guard snapshot == expected else { throw GlobalClaudeCredentialServiceError.concurrentModification }
            snapshot = GlobalClaudeCredentialSnapshot(account: expected.account ?? "test", data: replacement)
        }
    }
    func verifyCommitted(_ replacement: Data, basedOn original: GlobalClaudeCredentialSnapshot) throws {
        if readSnapshot().data != replacement { throw GlobalClaudeCredentialServiceError.committedDataMismatch }
    }
    func restore(_ original: GlobalClaudeCredentialSnapshot, replacing replacement: Data) throws {
        try lock.withLock {
            guard snapshot.data == replacement else { throw GlobalClaudeCredentialServiceError.concurrentModification }
            snapshot = original
        }
    }
}

struct DisabledClaudeStatusReader: ClaudeSessionStatusReading {
    func isInstalled() -> Bool { false }
    func readStatus() async throws -> ClaudeAuthStatus { throw ClaudeExecutableLocatorError.notFound }
}

struct DisabledCodexAccountService: CodexLoginServicing {
    func validate(authData: Data) async throws -> AccountValidationResult { throw CodexExecutableLocatorError.notFound(.success) }
    func loginNewAccount(openURL: @MainActor @escaping @Sendable (URL) -> Void) async throws -> AccountValidationResult {
        throw CodexExecutableLocatorError.notFound(.success)
    }
}

struct AppModelDependencies {
    let repository: AccountsRepository
    let codexCoordinator: CodexSessionCoordinator
    let claudeCoordinator: ClaudeSessionCoordinator
    let widgetPublisher: LimitsWidgetSnapshotPublisher
    let isolated: Bool

    static func make(environment: LimitsRuntimeEnvironment = .current) -> AppModelDependencies {
        guard let root = environment.isolatedRoot else {
            let repository = AccountsRepository()
            let globalCodex = GlobalCodexAuthService()
            let globalClaude = GlobalClaudeCredentialService()
            let claudeStatus = ClaudeAuthStatusService()
            return AppModelDependencies(
                repository: repository,
                codexCoordinator: CodexSessionCoordinator(globalStore: globalCodex, accountService: CodexAccountService()),
                claudeCoordinator: ClaudeSessionCoordinator(
                    globalStore: globalClaude,
                    statusReader: claudeStatus,
                    repository: repository
                ),
                widgetPublisher: LimitsWidgetSnapshotPublisher(),
                isolated: false
            )
        }

        let repository = AccountsRepository(
            persistence: AccountsPersistence(baseURL: root.appending(path: "Application Support/Limits")),
            vault: KeychainAuthVault(store: RuntimeMemoryKeychainStore())
        )
        let globalCodex = GlobalCodexAuthService(authURL: root.appending(path: "Codex/auth.json"))
        let globalClaude = RuntimeClaudeCredentialStore()
        let claudeStatus: any ClaudeSessionStatusReading = environment.disablesExternalProbes
            ? DisabledClaudeStatusReader()
            : ClaudeAuthStatusService()
        return AppModelDependencies(
            repository: repository,
            codexCoordinator: CodexSessionCoordinator(globalStore: globalCodex, accountService: DisabledCodexAccountService()),
            claudeCoordinator: ClaudeSessionCoordinator(
                globalStore: globalClaude,
                statusReader: claudeStatus,
                repository: repository,
                bridge: ClaudeStatuslineBridgeService(
                    homeDirectory: root.appending(path: "Home"),
                    appSupportDirectory: root.appending(path: "Application Support/Limits")
                )
            ),
            widgetPublisher: LimitsWidgetSnapshotPublisher(
                store: LimitsWidgetSnapshotStore(baseURL: root.appending(path: "AppGroup")),
                reloadTimelines: {}
            ),
            isolated: true
        )
    }
}
