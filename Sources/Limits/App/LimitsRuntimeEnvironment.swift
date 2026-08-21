import Foundation
import LimitsCore
import LimitsShared

struct LimitsRuntimeEnvironment {
    let storageLayout: LimitsStorageLayout
    let disablesExternalProbes: Bool
    let isUITest: Bool
    let initialAccountsSelection: String?
    let testColorScheme: String?

    static var current: LimitsRuntimeEnvironment {
        let environment = ProcessInfo.processInfo.environment
        let root = environment["LIMITS_TEST_ROOT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        return LimitsRuntimeEnvironment(
            storageLayout: root.map(LimitsStorageLayout.isolated) ?? .production(),
            disablesExternalProbes: environment["LIMITS_DISABLE_EXTERNAL_PROBES"] == "1",
            isUITest: environment["LIMITS_UI_TEST"] == "1",
            initialAccountsSelection: environment["LIMITS_TEST_ACCOUNTS_SELECTION"],
            testColorScheme: environment["LIMITS_TEST_COLOR_SCHEME"]
        )
    }

    func prepareUserDefaults() {
        guard isUITest, let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        if let initialAccountsSelection {
            UserDefaults.standard.set(initialAccountsSelection, forKey: "limits.accounts.selection")
        }
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
        lock.withLock { _ = values.removeValue(forKey: account) }
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

struct FixturePricingDownloader: OpenAIPricingDownloading {
    let directory: URL

    func download(_ url: URL) async throws -> OpenAIPricingDownload {
        let filename: String
        if url.host == "developers.openai.com" {
            filename = "api.md"
        } else if url.path.contains("agent-configuration/speed") {
            filename = "speed.md"
        } else {
            filename = "chatgpt.md"
        }
        let data = try Data(contentsOf: directory.appending(path: filename))
        return OpenAIPricingDownload(data: data, statusCode: 200, mimeType: "text/markdown", finalURL: url)
    }
}

struct AppModelDependencies {
    let repository: AccountsRepository
    let usageCoordinator: CodexUsageCoordinator
    let codexCoordinator: CodexSessionCoordinator
    let claudeCoordinator: ClaudeSessionCoordinator
    let widgetPublisher: LimitsWidgetSnapshotPublisher
    let isolated: Bool

    static func make(environment: LimitsRuntimeEnvironment = .current) -> AppModelDependencies {
        let layout = environment.storageLayout
        let usageRepository = CodexUsageRepository(
            persistence: CodexUsagePersistence(baseURL: layout.stateDirectory)
        )

        if !layout.isIsolated {
            let repository = AccountsRepository(
                persistence: AccountsPersistence(baseURL: layout.stateDirectory),
                usageRepository: usageRepository
            )
            let globalCodex = GlobalCodexAuthService(authURL: layout.codexAuthURL)
            let globalClaude = GlobalClaudeCredentialService(lockURL: layout.claudeGlobalLockURL)
            let claudeStatus = ClaudeAuthStatusService()
            let codexCoordinator = CodexSessionCoordinator(globalStore: globalCodex, accountService: CodexAccountService())
            return AppModelDependencies(
                repository: repository,
                usageCoordinator: CodexUsageCoordinator(
                    accountsRepository: repository,
                    usageRepository: usageRepository,
                    sessionCoordinator: codexCoordinator,
                    codexHome: layout.codexHome
                ),
                codexCoordinator: codexCoordinator,
                claudeCoordinator: ClaudeSessionCoordinator(
                    globalStore: globalClaude,
                    statusReader: claudeStatus,
                    repository: repository,
                    bridge: ClaudeStatuslineBridgeService(
                        homeDirectory: layout.homeDirectory,
                        appSupportDirectory: layout.stateDirectory
                    )
                ),
                widgetPublisher: LimitsWidgetSnapshotPublisher(
                    store: LimitsWidgetSnapshotStore(baseURL: layout.widgetDirectory)
                ),
                isolated: false
            )
        }

        let repository = AccountsRepository(
            persistence: AccountsPersistence(baseURL: layout.stateDirectory),
            usageRepository: usageRepository,
            vault: KeychainAuthVault(store: RuntimeMemoryKeychainStore())
        )
        let globalCodex = GlobalCodexAuthService(authURL: layout.codexAuthURL)
        let globalClaude = RuntimeClaudeCredentialStore()
        let claudeStatus: any ClaudeSessionStatusReading = environment.disablesExternalProbes
            ? DisabledClaudeStatusReader()
            : ClaudeAuthStatusService()
        let codexCoordinator = CodexSessionCoordinator(globalStore: globalCodex, accountService: DisabledCodexAccountService())
        return AppModelDependencies(
            repository: repository,
            usageCoordinator: CodexUsageCoordinator(
                accountsRepository: repository,
                usageRepository: usageRepository,
                sessionCoordinator: codexCoordinator,
                codexHome: layout.codexHome,
                allowsServerProbes: false,
                pricingDownloader: FixturePricingDownloader(directory: layout.pricingFixtureDirectory)
            ),
            codexCoordinator: codexCoordinator,
            claudeCoordinator: ClaudeSessionCoordinator(
                globalStore: globalClaude,
                statusReader: claudeStatus,
                repository: repository,
                bridge: ClaudeStatuslineBridgeService(
                    homeDirectory: layout.homeDirectory,
                    appSupportDirectory: layout.stateDirectory
                )
            ),
            widgetPublisher: LimitsWidgetSnapshotPublisher(
                store: LimitsWidgetSnapshotStore(baseURL: layout.widgetDirectory),
                reloadTimelines: {}
            ),
            isolated: true
        )
    }
}
