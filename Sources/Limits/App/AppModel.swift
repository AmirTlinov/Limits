import AppKit
import Foundation
import LimitsCore
import LimitsShared

@MainActor
final class AppModel: ObservableObject {
    enum PendingCredentialDeletion: Identifiable {
        case codex(StoredAccount)
        case claude(ClaudeStoredAccount)

        var id: UUID {
            switch self {
            case .codex(let account): account.id
            case .claude(let account): account.id
            }
        }

        var accountName: String {
            switch self {
            case .codex(let account): account.label
            case .claude(let account): account.label
            }
        }
    }

    struct CurrentCLIState {
        typealias Source = CodexSessionSource

        var source: Source = .missing
        var authFingerprint: String?
        var accountId: String?
        var authMode: String?
    }

    struct CurrentCLIOverview {
        let title: String
        let subtitle: String?
        let limits: String?
        let note: String?
    }

    typealias CurrentCLIProbe = CodexSessionProbe

    struct CurrentClaudeState {
        typealias Source = ClaudeSessionSource

        var source: Source = .notInstalled
        var authFingerprint: String?
    }

    struct CurrentClaudeOverview {
        let title: String
        let subtitle: String?
        let note: String?
    }

    typealias SidebarLimitSummary = LimitsCore.SidebarLimitSummary

    @Published private(set) var accounts: [StoredAccount] = []
    @Published private(set) var claudeAccounts: [ClaudeStoredAccount] = []
    @Published private(set) var currentCLIState = CurrentCLIState()
    @Published private(set) var currentCLIProbe: CurrentCLIProbe?
    @Published private(set) var isRefreshingCurrentCLIProbe = false
    @Published private(set) var currentClaudeState = CurrentClaudeState()
    @Published private(set) var currentClaudeStatus: ClaudeAuthStatus?
    @Published private(set) var currentClaudeValidatedAt: Date?
    @Published private(set) var currentClaudeLiveEvidence: ClaudeLiveEvidence?
    @Published private(set) var currentClaudeLiveBridgeStatus = ClaudeStatuslineBridgeStatus(installed: false, hasSnapshot: false, preservingOriginalStatusLine: false)
    @Published private(set) var providerOperationStates: [ProviderKind: ProviderOperationState] = [:]
    @Published var errorMessage: String?
    @Published var currentCLIProbeError: String?
    @Published var currentClaudeError: String?
    @Published var currentClaudeBridgeError: String?
    @Published private(set) var presentationNow = Date()
    @Published private(set) var providerCatalog = ProviderCatalogSnapshot(savedClaudeCount: 0, claudeSource: .notInstalled)
    @Published var pendingCredentialDeletion: PendingCredentialDeletion?

    private let accountsRepository: AccountsRepository
    private let codexSessionCoordinator: CodexSessionCoordinator
    private let claudeSessionCoordinator: ClaudeSessionCoordinator
    private let backgroundRefreshInterval: TimeInterval = 300
    private let presentationTickInterval: TimeInterval = 30
    private let currentCLIExpiredResetRetryInterval: TimeInterval = 300
    private let storedCodexAutoRefreshInterval: TimeInterval = 60
    private let widgetSnapshotPublisher: LimitsWidgetSnapshotPublisher
    private let isIsolatedRuntime: Bool
    private let storedCodexAutoRefreshRetryInterval: TimeInterval = 1_800
    private var backgroundRefreshTask: Task<Void, Never>?
    private var presentationClockTask: Task<Void, Never>?
    private var storedCodexAutoRefreshTask: Task<Void, Never>?
    private var currentValuesRefreshTask: Task<Void, Never>?
    private var currentValuesRefreshID: UUID?
    private var currentValuesRefreshIsForced = false
    private var lastStoredCodexAutoRefreshAttempt: [UUID: Date] = [:]
    private var lastCurrentCLIExpiredResetRefreshAttempt: Date?
    private var isRefreshingStoredCodexAccount = false
    private var persistedStateLoaded = false

    var isBusy: Bool {
        providerOperationStates.values.contains { $0.phase == .running }
    }

    var busyMessage: String? {
        providerOperationStates[.codex]?.progress ?? providerOperationStates[.claude]?.progress
    }

    func isProviderBusy(_ provider: ProviderKind) -> Bool {
        providerOperationStates[provider]?.phase == .running
    }

    func providerErrorMessage(_ provider: ProviderKind) -> String? {
        providerOperationStates[provider]?.error
    }

    func providerOperationState(_ provider: ProviderKind) -> ProviderOperationState {
        providerOperationStates[provider] ?? .idle
    }

    func cancelOperation(for provider: ProviderKind) {
        guard providerOperationStates[provider]?.canCancel == true else { return }
        switch provider {
        case .codex:
            Task { await codexSessionCoordinator.cancelCurrentOperation() }
        case .claude:
            break
        }
    }

    func invalidateLocalizedText() {
        objectWillChange.send()
    }

    init(dependencies: AppModelDependencies = .make()) {
        accountsRepository = dependencies.repository
        codexSessionCoordinator = dependencies.codexCoordinator
        claudeSessionCoordinator = dependencies.claudeCoordinator
        widgetSnapshotPublisher = dependencies.widgetPublisher
        isIsolatedRuntime = dependencies.isolated
        Task { await bootstrap() }
        startPresentationClockLoop()
        if !isIsolatedRuntime {
            startBackgroundRefreshLoop()
            startStoredCodexAutoRefreshLoop()
        }
    }

    deinit {
        backgroundRefreshTask?.cancel()
        presentationClockTask?.cancel()
        storedCodexAutoRefreshTask?.cancel()
        currentValuesRefreshTask?.cancel()
    }

    func bootstrap() async {
        defer { publishWidgetSnapshotIfPossible() }

        do {
            try await loadPersistedState()
            guard persistedStateLoaded else { return }
            await refreshCurrentValues(forceProbe: false)

            if accounts.isEmpty, case .external = currentCLIState.source {
                try await importCurrentCLIAuthNow()
                await refreshCurrentValues(forceProbe: true)
            }
            await refreshOneStaleStoredCodexAccountInBackground()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadPersistedState() async throws {
        let currentCodexFingerprint = try? await codexSessionCoordinator.currentAuthFingerprint()
        let currentClaudeFingerprint = try? await claudeSessionCoordinator.currentCredentialFingerprint()
        var snapshot = try await accountsRepository.open(
            currentCodexFingerprint: currentCodexFingerprint,
            currentClaudeFingerprint: currentClaudeFingerprint
        )
        if snapshot.access == .readWrite {
            snapshot = try await accountsRepository.purgeRetiredCredentials()
        } else if case .readOnlyRecovery(let version) = snapshot.access {
            setNotice(AccountsRepositoryError.readOnlyRecovery(schemaVersion: version).localizedDescription, provider: .codex)
        }
        applyRepositorySnapshot(snapshot)
        persistedStateLoaded = true
    }

    private func applyRepositorySnapshot(_ snapshot: AccountsRepositorySnapshot) {
        accounts = snapshot.state.accounts
        claudeAccounts = snapshot.state.claudeAccounts
        providerCatalog = ProviderCatalogSnapshot(
            savedClaudeCount: claudeAccounts.count,
            claudeSource: currentClaudeState.source
        )
    }

    private func applyClaudeProbeResult(_ result: ClaudeSessionProbeResult) {
        applyRepositorySnapshot(result.repositorySnapshot)
        currentClaudeState = CurrentClaudeState(source: result.source, authFingerprint: result.globalCredentialFingerprint)
        currentClaudeStatus = result.status
        currentClaudeValidatedAt = result.validatedAt
        currentClaudeLiveEvidence = result.evidence
        currentClaudeLiveBridgeStatus = result.bridgeStatus
        currentClaudeError = result.repositoryError
        providerCatalog = ProviderCatalogSnapshot(savedClaudeCount: claudeAccounts.count, claudeSource: result.source)
    }

    func refreshCurrentCLIState() async {
        defer { publishWidgetSnapshotIfPossible() }
        do {
            let observation = try await codexSessionCoordinator.observeCurrent(accounts: accounts)
            currentCLIState = CurrentCLIState(
                source: observation.source,
                authFingerprint: observation.authFingerprint,
                accountId: observation.accountID,
                authMode: observation.authMode
            )
            if observation.source == .missing {
                currentCLIProbe = nil
                currentCLIProbeError = nil
            }
        } catch {
            currentCLIState = CurrentCLIState(source: .unreadable, authFingerprint: nil, accountId: nil, authMode: nil)
            currentCLIProbe = nil
            currentCLIProbeError = nil
            errorMessage = error.localizedDescription
        }
    }

    func refreshCurrentCLIProbe(force: Bool = false) async {
        defer { publishWidgetSnapshotIfPossible() }
        guard !isCurrentCLIAuthMissing() else {
            currentCLIProbe = nil
            currentCLIProbeError = nil
            return
        }

        guard !isCurrentCLIAuthUnreadable() else {
            currentCLIProbe = nil
            currentCLIProbeError = nil
            return
        }

        guard let fingerprint = currentCLIState.authFingerprint else {
            currentCLIProbe = nil
            currentCLIProbeError = nil
            return
        }

        let now = Date()
        if !force, let probe = currentCLIProbe, CodexSessionPresentation.canReuse(
            probe,
            expectedFingerprint: fingerprint,
            now: now,
            ttl: LimitsFreshnessPolicy.defaultTTL
        ) {
            return
        }

        guard !isRefreshingCurrentCLIProbe else {
            return
        }

        isRefreshingCurrentCLIProbe = true
        defer { isRefreshingCurrentCLIProbe = false }

        do {
            guard case .published(let outcome) = try await codexSessionCoordinator.refreshCurrent() else {
                return
            }
            let result = outcome.validation
            currentCLIProbe = CurrentCLIProbe(
                fingerprint: result.authFingerprint,
                email: result.email,
                planType: result.planType,
                rateLimit: result.rateLimit,
                rateLimitsByLimitId: result.rateLimitsByLimitId,
                validatedAt: now,
                rateLimitError: result.rateLimitError
            )
            currentCLIProbeError = result.rateLimitError

            do {
                try await persistValidatedCurrentCLIAccountIfKnown(result)
                if result.authFingerprint != fingerprint {
                    await refreshCurrentCLIState()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        } catch {
            currentCLIProbe = nil
            currentCLIProbeError = error.localizedDescription
        }
    }

    func refreshCurrentCLIPanel(forceProbe: Bool = false) async {
        await refreshCurrentCLIState()
        await refreshCurrentCLIProbe(force: forceProbe)
    }

    func refreshCurrentClaudeState() async {
        defer { publishWidgetSnapshotIfPossible() }
        defer {
            providerCatalog = ProviderCatalogSnapshot(
                savedClaudeCount: claudeAccounts.count,
                claudeSource: currentClaudeState.source
            )
        }
        do {
            let result = try await claudeSessionCoordinator.probe()
            applyClaudeProbeResult(result)
            currentClaudeBridgeError = nil
        } catch {
            currentClaudeState = CurrentClaudeState(source: .unreadable, authFingerprint: nil)
            currentClaudeStatus = nil
            currentClaudeValidatedAt = nil
            currentClaudeLiveEvidence = nil
            currentClaudeError = error.localizedDescription
            currentClaudeLiveBridgeStatus = ClaudeStatuslineBridgeStatus(installed: false, hasSnapshot: false, preservingOriginalStatusLine: false)
        }
    }

    func addAccount() async {
        await runBusy(provider: .codex, L10n.tr("busy.signing_in"), canCancel: true) { [self] in
            let result = try await self.codexSessionCoordinator.loginNewAccount { url in
                NSWorkspace.shared.open(url)
            }
            try await self.upsertAccount(from: result, preferredLabel: result.email)
            await self.refreshCurrentCLIState()
            await self.refreshCurrentCLIProbe(force: true)
        }
    }

    func importCurrentCLIAuth() async {
        await runBusy(provider: .codex, L10n.tr("busy.importing_current_cli")) { [self] in
            try await self.importCurrentCLIAuthNow()
            await self.refreshCurrentCLIState()
            await self.refreshCurrentCLIProbe(force: true)
        }
    }

    func importCurrentClaudeAuth() async {
        await runBusy(provider: .claude, L10n.tr("busy.importing_current_claude")) { [self] in
            try await self.importCurrentClaudeAuthNow()
            await self.refreshCurrentClaudeState()
        }
    }

    func activateAccount(_ account: StoredAccount) async {
        await runBusy(provider: .codex, L10n.tr("busy.switching_global_auth")) { [self] in
            do {
                let authData = try await self.accountsRepository.credential(provider: .codex, accountID: account.id)
                self.currentCLIProbe = nil
                self.currentCLIProbeError = nil
                _ = try await self.codexSessionCoordinator.switchAccount(account, authData: authData) { result in
                    try await self.persistValidatedAccount(result, forAccountID: account.id)
                }
                await self.refreshCurrentCLIState()
                await self.refreshCurrentCLIProbe(force: true)
            } catch {
                await self.refreshCurrentCLIState()
                throw error
            }
        }
    }

    func reauthenticateAccount(_ account: StoredAccount) async {
        await runBusy(provider: .codex, L10n.tr("busy.reauthenticating", account.label), canCancel: true) { [self] in
            let result = try await self.codexSessionCoordinator.loginNewAccount { url in
                NSWorkspace.shared.open(url)
            }
            switch AccountResolution.reauthenticationTarget(requested: account, result: result, accounts: self.accounts) {
            case .requestedAccount(let id):
                try await self.upsertAccount(from: result, preferredLabel: account.label, existingID: id)
            case .existingAccount(let id):
                let label = self.accounts.first(where: { $0.id == id })?.label ?? result.email
                try await self.upsertAccount(from: result, preferredLabel: label, existingID: id)
                self.setNotice(L10n.tr("account.reauth.different_existing", account.label), provider: .codex)
            case .newAccount:
                try await self.upsertAccount(from: result, preferredLabel: result.email, forceNew: true)
                self.setNotice(L10n.tr("account.reauth.different_new", account.label), provider: .codex)
            }
            await self.refreshCurrentCLIState()
            await self.refreshCurrentCLIProbe(force: true)
        }
    }

    func activateClaudeAccount(_ account: ClaudeStoredAccount) async {
        await runBusy(provider: .claude, L10n.tr("busy.switching_claude")) { [self] in
            self.currentClaudeLiveEvidence = nil
            do {
                let result = try await self.claudeSessionCoordinator.switchAccount(account)
                self.applyClaudeProbeResult(result)
            } catch {
                await self.refreshCurrentClaudeState()
                throw error
            }
        }
    }

    func refreshCurrentClaudeAccount() async {
        await runBusy(provider: .claude, L10n.tr("busy.refreshing_claude")) { [self] in
            await self.refreshCurrentClaudeState()
        }
    }

    func installClaudeLiveLimitsBridge() async {
        await runBusy(provider: .claude, L10n.tr("busy.connecting_claude_live")) { [self] in
            self.currentClaudeBridgeError = nil
            do {
                try await self.claudeSessionCoordinator.installBridge()
            } catch {
                self.currentClaudeBridgeError = error.localizedDescription
                throw error
            }
            await self.refreshCurrentClaudeState()
        }
    }

    func uninstallClaudeLiveLimitsBridge() async {
        await runBusy(provider: .claude, L10n.tr("busy.disconnecting_claude_bridge")) { [self] in
            self.currentClaudeBridgeError = nil
            do {
                try await self.claudeSessionCoordinator.uninstallBridge()
            } catch {
                self.currentClaudeBridgeError = error.localizedDescription
                throw error
            }
            await self.refreshCurrentClaudeState()
        }
    }

    func refreshCurrentValues(forceProbe: Bool = true) async {
        if let activeTask = currentValuesRefreshTask {
            let needsForcedFollowup = forceProbe && !currentValuesRefreshIsForced
            await activeTask.value
            if needsForcedFollowup {
                await refreshCurrentValues(forceProbe: true)
            }
            return
        }

        let refreshID = UUID()
        currentValuesRefreshID = refreshID
        currentValuesRefreshIsForced = forceProbe
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performCurrentValuesRefresh(forceProbe: forceProbe)
            self.finishCurrentValuesRefresh(id: refreshID)
        }
        currentValuesRefreshTask = task
        await task.value
    }

    private func finishCurrentValuesRefresh(id: UUID) {
        if currentValuesRefreshID == id {
            currentValuesRefreshTask = nil
            currentValuesRefreshID = nil
            currentValuesRefreshIsForced = false
        }
    }

    private func performCurrentValuesRefresh(forceProbe: Bool) async {
        if !isProviderBusy(.codex) {
            await refreshCurrentCLIPanel(forceProbe: forceProbe)
        }
        if !isProviderBusy(.claude) {
            await refreshCurrentClaudeState()
        }
    }

    private func startPresentationClockLoop() {
        guard presentationClockTask == nil else {
            return
        }

        let interval = UInt64(presentationTickInterval * 1_000_000_000)
        presentationClockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else {
                    break
                }
                await self?.tickPresentationClock()
            }
        }
    }

    private func tickPresentationClock() async {
        let now = Date()
        presentationNow = now
        await refreshCurrentCLIProbeIfResetExpired(now: now)
    }

    private func refreshCurrentCLIProbeIfResetExpired(now: Date) async {
        guard
            currentCLIProbeError == nil,
            currentCLIProbe != nil,
            currentCLIProbeHasExpiredReset(now: now),
            CodexAccountsPresentationPolicy.canAttemptRefresh(
                lastAttempt: lastCurrentCLIExpiredResetRefreshAttempt,
                now: now,
                retryInterval: currentCLIExpiredResetRetryInterval
            )
        else {
            return
        }

        lastCurrentCLIExpiredResetRefreshAttempt = now
        await refreshCurrentCLIProbe(force: false)
    }

    private func startBackgroundRefreshLoop() {
        guard backgroundRefreshTask == nil else {
            return
        }

        let interval = UInt64(backgroundRefreshInterval * 1_000_000_000)
        backgroundRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else {
                    break
                }
                await self?.refreshCurrentSurfacesInBackground()
            }
        }
    }

    private func refreshCurrentSurfacesInBackground() async {
        await refreshCurrentValues(forceProbe: false)
    }

    private func startStoredCodexAutoRefreshLoop() {
        guard storedCodexAutoRefreshTask == nil else {
            return
        }

        let initialDelay = UInt64(10 * 1_000_000_000)
        let interval = UInt64(storedCodexAutoRefreshInterval * 1_000_000_000)
        storedCodexAutoRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: initialDelay)
            while !Task.isCancelled {
                await self?.refreshOneStaleStoredCodexAccountInBackground()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    private func refreshOneStaleStoredCodexAccountInBackground(now: Date = Date()) async {
        guard !isProviderBusy(.codex), !isRefreshingCurrentCLIProbe, !isRefreshingStoredCodexAccount else {
            return
        }

        guard let accountID = CodexAccountsPresentationPolicy.nextAccountIDForAutoRefresh(
            accounts: accounts,
            currentAccountID: currentStoredCodexAccountID(),
            lastAttempts: lastStoredCodexAutoRefreshAttempt,
            now: now,
            retryInterval: storedCodexAutoRefreshRetryInterval
        ) else {
            return
        }

        guard let account = accounts.first(where: { $0.id == accountID }) else {
            return
        }

        lastStoredCodexAutoRefreshAttempt[accountID] = now
        isRefreshingStoredCodexAccount = true
        defer { isRefreshingStoredCodexAccount = false }

        await validateAccount(account)
    }

    private func currentStoredCodexAccountID() -> UUID? {
        if case .stored(let id) = currentCLIState.source {
            return id
        }
        return nil
    }

    func validateAccount(_ account: StoredAccount) async {
        defer { publishWidgetSnapshotIfPossible() }
        do {
            let authData = try await accountsRepository.credential(provider: .codex, accountID: account.id)
            let result = try await codexSessionCoordinator.validateStored(authData: authData)
            try await persistValidatedAccount(result, forAccountID: account.id)
        } catch {
            do {
                try await updateAccount(account.id) { stored in
                    stored.lastValidatedAt = Date()
                    stored.updatedAt = Date()
                    stored.status = classifyValidationError(error)
                    stored.statusMessage = validationStatusMessage(for: error)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        if isCurrentCLIAccount(account) {
            await refreshCurrentCLIProbe(force: true)
        }
    }

    func deleteAccount(_ account: StoredAccount) async {
        await runBusy(provider: .codex, L10n.tr("busy.deleting", account.label)) { [self] in
            let snapshot = try await self.accountsRepository.deleteAccount(provider: .codex, accountID: account.id)
            self.applyRepositorySnapshot(snapshot)
            await self.refreshCurrentCLIState()
            await self.refreshCurrentCLIProbe(force: true)
        }
    }

    func deleteClaudeAccount(_ account: ClaudeStoredAccount) async {
        await runBusy(provider: .claude, L10n.tr("busy.deleting", account.label)) { [self] in
            let snapshot = try await self.accountsRepository.deleteAccount(provider: .claude, accountID: account.id)
            self.applyRepositorySnapshot(snapshot)
            await self.refreshCurrentClaudeState()
        }
    }

    func requestDeleteAccount(_ account: StoredAccount) {
        pendingCredentialDeletion = .codex(account)
    }

    func requestDeleteClaudeAccount(_ account: ClaudeStoredAccount) {
        pendingCredentialDeletion = .claude(account)
    }

    func cancelCredentialDeletion() {
        pendingCredentialDeletion = nil
    }

    func confirmCredentialDeletion() async {
        guard let pendingCredentialDeletion else { return }
        self.pendingCredentialDeletion = nil
        switch pendingCredentialDeletion {
        case .codex(let account):
            await deleteAccount(account)
        case .claude(let account):
            await deleteClaudeAccount(account)
        }
    }

    func isCurrentCLIAccount(_ account: StoredAccount) -> Bool {
        if case .stored(let id) = currentCLIState.source {
            return id == account.id
        }
        return false
    }

    func isCurrentClaudeAccount(_ account: ClaudeStoredAccount) -> Bool {
        if case .stored(let id) = currentClaudeState.source {
            return id == account.id
        }
        return false
    }

    func claudeLiveBridgeInstalled() -> Bool {
        currentClaudeLiveBridgeStatus.installed
    }

    func claudeLiveBridgeSnapshotUpdatedAt() -> Date? {
        currentClaudeLiveEvidence?.snapshotAt
    }

    func currentCLIReferenceAccount() -> StoredAccount? {
        switch currentCLIState.source {
        case .stored(let id):
            return accounts.first(where: { $0.id == id })
        case .external(let accountId):
            if let accountId, let matched = accounts.first(where: { $0.accountId == accountId }) {
                return matched
            }
            return currentCLIImportedAccount()
        case .missing, .unreadable:
            return nil
        }
    }

    func currentClaudeReferenceAccount() -> ClaudeStoredAccount? {
        switch currentClaudeState.source {
        case .stored(let id):
            return claudeAccounts.first(where: { $0.id == id })
        case .external:
            guard let identity = currentClaudeStatus?.stableIdentity else { return nil }
            return AccountResolution.storedClaudeMatch(
                identity: identity,
                fingerprint: currentClaudeState.authFingerprint,
                accounts: claudeAccounts
            )
        case .notInstalled, .loggedOut, .unreadable:
            return nil
        }
    }

    func currentCLIOverview() -> CurrentCLIOverview {
        let account = currentCLIReferenceAccount()
        let liveLimits = CodexSessionPresentation.panelSummary(
            probe: currentCLIProbe,
            probeError: currentCLIProbeError,
            now: presentationNow
        )
        let probeBackedSubtitle = subtitle(for: account, probe: currentCLIProbe)

        switch currentCLIState.source {
        case .stored:
            return CurrentCLIOverview(
                title: titleForStoredAccount(account, probe: currentCLIProbe),
                subtitle: probeBackedSubtitle,
                limits: liveLimits,
                note: noteForStoredAccount(account)
            )
        case .external:
            return CurrentCLIOverview(
                title: titleForExternalAuth(account, probe: currentCLIProbe),
                subtitle: probeBackedSubtitle,
                limits: liveLimits,
                note: noteForExternalAuth(account)
            )
        case .missing:
            return CurrentCLIOverview(
                title: L10n.tr("cli.no_auth.title"),
                subtitle: nil,
                limits: nil,
                note: accounts.isEmpty ? L10n.tr("cli.no_auth.note.empty") : L10n.tr("cli.no_auth.note.saved")
            )
        case .unreadable:
            return CurrentCLIOverview(
                title: L10n.tr("cli.auth_unreadable.title"),
                subtitle: nil,
                limits: nil,
                note: accounts.isEmpty ? L10n.tr("cli.auth_unreadable.note.empty") : L10n.tr("cli.auth_unreadable.note.saved")
            )
        }
    }

    func currentClaudeOverview() -> CurrentClaudeOverview {
        let account = currentClaudeReferenceAccount()

        switch currentClaudeState.source {
        case .stored:
            return CurrentClaudeOverview(
                title: account?.label ?? currentClaudeStatus?.email ?? "Claude Code",
                subtitle: claudeSubtitle(account: account, status: currentClaudeStatus),
                note: claudeNote(account: account)
            )
        case .external:
            return CurrentClaudeOverview(
                title: currentClaudeStatus?.email ?? account?.label ?? "Claude Code",
                subtitle: claudeSubtitle(account: account, status: currentClaudeStatus),
                note: account == nil ? L10n.tr("claude.import_current_note") : claudeNote(account: account)
            )
        case .loggedOut:
            return CurrentClaudeOverview(
                title: L10n.tr("claude.no_auth.title"),
                subtitle: nil,
                note: L10n.tr("claude.no_auth.note")
            )
        case .notInstalled:
            return CurrentClaudeOverview(
                title: L10n.tr("claude.not_installed.title"),
                subtitle: nil,
                note: L10n.tr("claude.not_installed.note")
            )
        case .unreadable:
            return CurrentClaudeOverview(
                title: L10n.tr("claude.unreadable.title"),
                subtitle: nil,
                note: currentClaudeError ?? L10n.tr("claude.unreadable.note")
            )
        }
    }

    func shouldOfferAddAccountAsPrimaryAction() -> Bool {
        accounts.isEmpty && (isCurrentCLIAuthMissing() || isCurrentCLIAuthUnreadable())
    }

    func publishWidgetSnapshotNow() {
        publishWidgetSnapshotIfPossible()
    }

    func trayStatusSnapshot(
        filter: AccountsSidebarFilter,
        now: Date = .now
    ) -> TrayStatusSnapshot {
        let sharedSnapshot = makeWidgetSnapshot(now: now)
        let codexLimit = trayFiveHourLimitSnapshot(provider: sharedSnapshot.provider(.codex), now: now)
        let claudeLimit = trayFiveHourLimitSnapshot(provider: sharedSnapshot.provider(.claude), now: now)
        return TrayStatusPresentation.snapshot(
            filter: filter,
            catalog: providerCatalog,
            codex: trayProviderAvailability(for: .codex, limit: codexLimit, now: now),
            claude: trayProviderAvailability(for: .claude, limit: claudeLimit, now: now),
            codexLimit: codexLimit,
            claudeLimit: claudeLimit
        )
    }

    func makeWidgetSnapshot(now: Date = .now) -> LimitsWidgetSnapshot {
        let codexOverview = currentCLIOverview()
        let codexLimits = WidgetPresentationPolicy.limitSnapshots(from: currentCLIDisplayRateLimitSections(now: now), now: now)
        let codexObservedAt = currentCLIValidatedAt()
        let claudeOverview = currentClaudeOverview()
        let claudeLimits = WidgetPresentationPolicy.limitSnapshots(from: currentClaudeLiveRateLimitSections(now: now), now: now)
        let claudeObservedAt = claudeLiveBridgeSnapshotUpdatedAt() ?? claudeValidatedAt()

        let codexProvider = LimitsWidgetProviderSnapshot(
                    id: .codex,
                    title: codexOverview.title,
                    subtitle: codexOverview.subtitle,
                    status: widgetCodexStatus(limits: codexLimits),
                    limits: codexLimits,
                    observedAt: codexObservedAt,
                    freshUntil: WidgetPresentationPolicy.freshUntil(observedAt: codexObservedAt, limits: codexLimits),
                    note: codexOverview.note ?? currentCLIProbeError
                )
        let claudeProvider = LimitsWidgetProviderSnapshot(
                    id: .claude,
                    title: claudeOverview.title,
                    subtitle: claudeOverview.subtitle,
                    status: widgetClaudeStatus(limits: claudeLimits),
                    limits: claudeLimits,
                    observedAt: claudeObservedAt,
                    freshUntil: WidgetPresentationPolicy.freshUntil(observedAt: claudeObservedAt, limits: claudeLimits),
                    note: claudeOverview.note ?? currentClaudeBridgeError ?? currentClaudeError
                )
        let byID: [LimitsWidgetProviderID: LimitsWidgetProviderSnapshot] = [
            .codex: codexProvider,
            .claude: claudeProvider,
        ]
        let providers = providerCatalog.widgetProviderIDs.compactMap { byID[$0] }
        return LimitsWidgetSnapshot(generatedAt: now, providers: providers)
    }

    func storedCodexAccountHasFreshCompactLimits(_ account: StoredAccount, now: Date = .now) -> Bool {
        let limits = WidgetPresentationPolicy.limitSnapshots(
            from: CodexAccountsPresentationPolicy.storedRateLimitSections(
                primary: account.lastRateLimit,
                byLimitId: account.lastRateLimitsByLimitId,
                observedAt: account.lastValidatedAt,
                now: now
            ),
            now: now
        )
        guard limits.contains(where: { $0.remainingPercent != nil }) else { return false }
        guard
            let observedAt = account.lastValidatedAt,
            let freshUntil = WidgetPresentationPolicy.freshUntil(observedAt: observedAt, limits: limits)
        else {
            return false
        }
        return observedAt <= now && now < freshUntil
    }

    private func widgetCodexStatus(limits: [LimitsWidgetLimitSnapshot]) -> LimitsWidgetProviderStatus {
        switch currentCLIState.source {
        case .missing:
            return .unavailable
        case .unreadable:
            return .error
        case .stored, .external:
            if limits.contains(where: { $0.remainingPercent != nil }) {
                return .available
            }
            return currentCLIProbeError == nil ? .noData : .error
        }
    }

    private func widgetClaudeStatus(limits: [LimitsWidgetLimitSnapshot]) -> LimitsWidgetProviderStatus {
        switch currentClaudeState.source {
        case .notInstalled, .loggedOut:
            return .unavailable
        case .unreadable:
            return .error
        case .stored, .external:
            if limits.contains(where: { $0.remainingPercent != nil }) {
                return .available
            }
            return currentClaudeBridgeError == nil ? .noData : .error
        }
    }

    private func trayProviderAvailability(
        for provider: TrayStatusProvider,
        limit: TrayLimitSnapshot,
        now: Date
    ) -> TrayProviderAvailability {
        switch provider {
        case .codex:
            let currentIsAvailable: Bool = {
                guard limit.remainingPercent != nil else { return false }
                return currentCLIReferenceAccount()?.status == .ok || currentCLIReferenceAccount() == nil
            }()
            let storedAvailable = accounts.filter { account in
                !isCurrentCLIAccount(account)
                    && account.status == .ok
                    && storedCodexAccountHasFreshCompactLimits(account, now: now)
            }.count
            return TrayProviderAvailability(
                remainingPercent: limit.remainingPercent,
                availableAccounts: (currentIsAvailable ? 1 : 0) + storedAvailable,
                totalAccounts: visibleCodexAccountCount()
            )
        case .claude:
            return TrayProviderAvailability(
                remainingPercent: limit.remainingPercent,
                availableAccounts: limit.remainingPercent == nil ? 0 : 1,
                totalAccounts: visibleClaudeAccountCount()
            )
        }
    }

    private func trayFiveHourLimitSnapshot(
        provider: LimitsWidgetProviderSnapshot?,
        now: Date
    ) -> TrayLimitSnapshot {
        guard let provider else {
            return TrayLimitSnapshot(remainingPercent: nil, resetText: nil)
        }
        let freshLimits = provider.limitsForCompactSurface(at: now)
        let limit = freshLimits
            .first(where: { $0.id.contains("five_hour") || $0.title == L10n.tr("limit.five_hour") })
            ?? freshLimits.first
        return TrayLimitSnapshot(
            remainingPercent: limit?.remainingPercent,
            resetText: limit?.resetDate.map { RateLimitResetFormatter.compactText(for: $0, now: now) }
        )
    }

    private func visibleCodexAccountCount() -> Int {
        let currentCountsAsAccount = ProviderPresentation.currentCodexCountsAsAccount(currentCLIState.source)
        let storedOtherCount = accounts.filter { !isCurrentCLIAccount($0) }.count
        return (currentCountsAsAccount ? 1 : 0) + storedOtherCount
    }

    private func visibleClaudeAccountCount() -> Int {
        let currentCountsAsAccount = ProviderPresentation.currentClaudeCountsAsAccount(currentClaudeState.source)
        let storedOtherCount = claudeAccounts.filter { !isCurrentClaudeAccount($0) }.count
        return (currentCountsAsAccount ? 1 : 0) + storedOtherCount
    }

    private func publishWidgetSnapshotIfPossible(now: Date = .now) {
        do {
            let published = try widgetSnapshotPublisher.publish(makeWidgetSnapshot(now: now))
            if published {
                RuntimeLog.widget.debug("widget snapshot published")
            }
        } catch {
            RuntimeLog.widget.warning("widget snapshot publish failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func currentCLIProbeWarningText() -> String? {
        currentCLIProbeError.map { CodexSessionPresentation.probeNote(for: $0) }
    }

    func isCurrentCLIAuthMissing() -> Bool {
        if case .missing = currentCLIState.source {
            return true
        }
        return false
    }

    func isCurrentCLIAuthUnreadable() -> Bool {
        if case .unreadable = currentCLIState.source {
            return true
        }
        return false
    }

    func hasCurrentCLIAuthToImport() -> Bool {
        guard case .external = currentCLIState.source else {
            return false
        }
        return currentCLIImportedAccount() == nil
    }

    func hasCurrentClaudeAuthToImport() -> Bool {
        if case .external = currentClaudeState.source {
            return true
        }
        return false
    }

    private func importCurrentCLIAuthNow() async throws {
        for _ in 0..<2 {
            if case .published(let outcome) = try await codexSessionCoordinator.refreshCurrent() {
                let result = outcome.validation
                try await upsertAccount(from: result, preferredLabel: result.email)
                return
            }
        }
        throw CodexSessionCoordinatorError.sessionChanged
    }

    private func currentCLIImportedAccount() -> StoredAccount? {
        AccountResolution.importedCodexAccount(
            fingerprint: currentCLIState.authFingerprint,
            accountId: currentCLIState.accountId,
            email: currentCLIProbe?.email,
            accounts: accounts
        )
    }

    private func importCurrentClaudeAuthNow() async throws {
        let capture = try await claudeSessionCoordinator.captureCurrentCredential()
        let credential = capture.credential
        let status = capture.status

        guard status.loggedIn, let email = status.email else {
            throw ClaudeCredentialSwitchTransactionError.notLoggedIn
        }

        try await upsertClaudeAccount(
            credential: credential,
            status: status,
            preferredLabel: email
        )
    }

    private func upsertAccount(
        from result: AccountValidationResult,
        preferredLabel: String,
        existingID: UUID? = nil,
        forceNew: Bool = false
    ) async throws {
        let existingIndex: Int? = {
            if forceNew {
                return nil
            }
            if let existingID {
                return accounts.firstIndex(where: { $0.id == existingID })
            }
            if let accountId = result.identity.accountId {
                return accounts.firstIndex(where: { $0.accountId == accountId })
            }
            return accounts.firstIndex(where: { $0.email.caseInsensitiveCompare(result.email) == .orderedSame })
        }()

        let recordID: UUID
        let label: String
        let createdAt: Date

        if let existingIndex {
            recordID = accounts[existingIndex].id
            label = accounts[existingIndex].label
            createdAt = accounts[existingIndex].createdAt
        } else {
            recordID = UUID()
            label = makeUniqueLabel(base: preferredLabel)
            createdAt = Date()
        }

        let updatedRecord = StoredAccount(
            id: recordID,
            label: label,
            email: result.email,
            accountId: result.identity.accountId,
            planType: result.planType,
            createdAt: createdAt,
            updatedAt: Date(),
            lastValidatedAt: Date(),
            status: resolveStatus(from: result.rateLimit),
            statusMessage: result.rateLimitError ?? statusMessage(for: result.rateLimit),
            lastRateLimit: result.rateLimit,
            lastRateLimitsByLimitId: result.rateLimitsByLimitId,
            authFingerprint: result.authFingerprint,
            keychainAccount: ""
        )

        let snapshot = try await accountsRepository.saveCodexAccount(updatedRecord, credential: result.authData)
        applyRepositorySnapshot(snapshot)
    }

    private func updateAccount(_ id: UUID, mutate: (inout StoredAccount) -> Void) async throws {
        guard var account = accounts.first(where: { $0.id == id }) else {
            return
        }
        mutate(&account)
        let snapshot = try await accountsRepository.updateCodexAccount(account)
        applyRepositorySnapshot(snapshot)
    }

    private func persistValidatedCurrentCLIAccountIfKnown(_ result: AccountValidationResult) async throws {
        guard let accountID = knownAccountID(for: result) else {
            return
        }

        try await persistValidatedAccount(result, forAccountID: accountID)
    }

    private func persistValidatedAccount(_ result: AccountValidationResult, forAccountID id: UUID) async throws {
        guard let account = accounts.first(where: { $0.id == id }) else {
            return
        }

        var stored = account
        stored.email = result.email
        stored.planType = result.planType
        stored.accountId = result.identity.accountId
        stored.authFingerprint = result.authFingerprint
        stored.lastValidatedAt = Date()
        stored.updatedAt = Date()
        stored.lastRateLimit = result.rateLimit
        stored.lastRateLimitsByLimitId = result.rateLimitsByLimitId
        stored.status = resolveStatus(from: result.rateLimit)
        stored.statusMessage = result.rateLimitError ?? statusMessage(for: result.rateLimit)
        let snapshot = try await accountsRepository.saveCodexAccount(stored, credential: result.authData)
        applyRepositorySnapshot(snapshot)
    }

    private func knownAccountID(for result: AccountValidationResult) -> UUID? {
        if case .stored(let id) = currentCLIState.source {
            return id
        }

        if let matched = AccountResolution.importedCodexAccount(
            fingerprint: result.authFingerprint,
            accountId: result.identity.accountId,
            email: result.email,
            accounts: accounts
        ) {
            return matched.id
        }

        return nil
    }

    private func upsertClaudeAccount(
        credential: Data,
        status: ClaudeAuthStatus,
        preferredLabel: String,
        existingID: UUID? = nil
    ) async throws {
        let fingerprint = CodexAuthBlob.fingerprint(for: credential)
        let existingIndex: Int? = {
            if let existingID {
                return claudeAccounts.firstIndex(where: { $0.id == existingID })
            }
            guard let identity = status.stableIdentity else { return nil }
            guard let match = AccountResolution.storedClaudeMatch(
                identity: identity,
                fingerprint: fingerprint,
                accounts: claudeAccounts
            ) else { return nil }
            return claudeAccounts.firstIndex(where: { $0.id == match.id })
        }()

        let recordID: UUID
        let label: String
        let createdAt: Date

        if let existingIndex {
            recordID = claudeAccounts[existingIndex].id
            label = claudeAccounts[existingIndex].label
            createdAt = claudeAccounts[existingIndex].createdAt
        } else {
            recordID = UUID()
            label = makeUniqueClaudeLabel(base: preferredLabel)
            createdAt = Date()
        }

        let updatedRecord = ClaudeStoredAccount(
            id: recordID,
            label: label,
            email: status.email ?? preferredLabel,
            subscriptionType: status.subscriptionType ?? "unknown",
            authMethod: status.authMethod,
            orgId: status.orgId,
            orgName: status.orgName,
            createdAt: createdAt,
            updatedAt: Date(),
            lastValidatedAt: Date(),
            status: .ok,
            statusMessage: L10n.tr("claude.account.ready"),
            authFingerprint: fingerprint,
            keychainAccount: ""
        )

        let snapshot = try await accountsRepository.saveClaudeAccount(updatedRecord, credential: credential)
        applyRepositorySnapshot(snapshot)
    }

    private func runBusy(
        provider: ProviderKind,
        _ message: String,
        canCancel: Bool = false,
        operation: @escaping () async throws -> Void
    ) async {
        guard !isProviderBusy(provider) else { return }
        let existingNotice = providerOperationStates[provider]?.notice
        providerOperationStates[provider] = ProviderOperationState(
            phase: .running,
            progress: message,
            canCancel: canCancel,
            notice: existingNotice,
            error: nil
        )

        do {
            try await operation()
            providerOperationStates[provider] = ProviderOperationState(notice: providerOperationStates[provider]?.notice)
            errorMessage = nil
        } catch is CancellationError {
            providerOperationStates[provider] = ProviderOperationState(notice: L10n.tr("operation.cancelled"))
        } catch {
            providerOperationStates[provider] = ProviderOperationState(
                notice: providerOperationStates[provider]?.notice,
                error: error.localizedDescription
            )
        }
    }

    private func setNotice(_ notice: String, provider: ProviderKind) {
        var state = providerOperationStates[provider] ?? .idle
        state.notice = notice
        providerOperationStates[provider] = state
    }

    private func resolveStatus(from rateLimit: RateLimitSnapshotModel?) -> AccountStatus {
        guard let rateLimit else {
            return .ok
        }
        return rateLimit.isReached ? .limitReached : .ok
    }

    private func statusMessage(for rateLimit: RateLimitSnapshotModel?) -> String? {
        guard let rateLimit else { return nil }

        if let reachedType = rateLimit.rateLimitReachedType {
            return reachedType.replacingOccurrences(of: "_", with: " ").capitalized
        }

        if let primary = rateLimit.primary {
            return L10n.usedFiveHours(primary.usedPercent)
        }

        return nil
    }

    private func classifyValidationError(_ error: Error) -> AccountStatus {
        AccountResolution.validationStatus(forErrorMessage: error.localizedDescription)
    }

    private func validationStatusMessage(for error: Error) -> String {
        switch classifyValidationError(error) {
        case .needsReauth:
            return L10n.tr("account.needs_login")
        case .validationFailed, .unknown, .ok, .limitReached:
            return error.localizedDescription
        }
    }

    private func makeUniqueLabel(base: String) -> String {
        guard accounts.contains(where: { $0.label.caseInsensitiveCompare(base) == .orderedSame }) else {
            return base
        }

        var counter = 2
        while true {
            let candidate = "\(base) \(counter)"
            if !accounts.contains(where: { $0.label.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return candidate
            }
            counter += 1
        }
    }

    private func makeUniqueClaudeLabel(base: String) -> String {
        guard !claudeAccounts.contains(where: { $0.label.caseInsensitiveCompare(base) == .orderedSame }) else {
            var counter = 2
            while true {
                let candidate = "\(base) \(counter)"
                if !claudeAccounts.contains(where: { $0.label.caseInsensitiveCompare(candidate) == .orderedSame }) {
                    return candidate
                }
                counter += 1
            }
        }
        return base
    }

    private func subtitle(for account: StoredAccount?, probe: CurrentCLIProbe?) -> String? {
        if let account {
            if account.label.caseInsensitiveCompare(account.email) != .orderedSame {
                return account.email
            }
            if let probe, probe.planType.caseInsensitiveCompare("unknown") != .orderedSame {
                return localizedPlan(probe.planType)
            }
            if account.planType.caseInsensitiveCompare("unknown") != .orderedSame {
                return localizedPlan(account.planType)
            }
            return nil
        }

        if let probe, probe.planType.caseInsensitiveCompare("unknown") != .orderedSame {
            return localizedPlan(probe.planType)
        }
        return nil
    }

    func currentCLIRateLimitSections(now: Date = .now) -> [RateLimitDisplaySection] {
        CodexSessionPresentation.rateLimitSections(
            probe: currentCLIProbe,
            probeError: currentCLIProbeError,
            now: now
        )
    }

    func currentCLIDisplayRateLimitSections(now: Date = .now) -> [RateLimitDisplaySection] {
        let liveSections = currentCLIRateLimitSections(now: now)
        if !liveSections.isEmpty {
            return liveSections
        }

        guard let account = currentCLIReferenceAccount() else {
            return []
        }

        return CodexAccountsPresentationPolicy.storedRateLimitSections(
            primary: account.lastRateLimit,
            byLimitId: account.lastRateLimitsByLimitId,
            observedAt: account.lastValidatedAt,
            now: now
        )
    }

    func currentClaudeLiveRateLimitSections(now: Date? = nil) -> [RateLimitDisplaySection] {
        ClaudeLivePresentation.rateLimitSections(evidence: currentClaudeLiveEvidence, now: now ?? presentationNow)
    }

    func rateLimitSections(for account: StoredAccount, now: Date = .now) -> [RateLimitDisplaySection] {
        let useLiveProbe = isCurrentCLIAccount(account) && currentCLIProbe?.fingerprint == account.authFingerprint
        if useLiveProbe {
            return currentCLIRateLimitSections(now: now)
        }

        return CodexAccountsPresentationPolicy.storedRateLimitSections(
            primary: account.lastRateLimit,
            byLimitId: account.lastRateLimitsByLimitId,
            observedAt: account.lastValidatedAt,
            now: now
        )
    }

    func sortedCodexAccountsForSidebar(now: Date = .now) -> [StoredAccount] {
        let summaries = Dictionary(
            uniqueKeysWithValues: accounts.map { account in
                (account.id, sidebarLimitSummary(for: account, now: now))
            }
        )
        return CodexAccountsPresentationPolicy.sortedForSidebar(accounts, summaries: summaries)
    }

    func currentCLISidebarLimitSummary(now: Date = .now) -> SidebarLimitSummary? {
        CodexAccountsPresentationPolicy.sidebarLimitSummary(
            primary: currentCLIProbe?.rateLimit,
            byLimitId: currentCLIProbe?.rateLimitsByLimitId,
            observedAt: currentCLIProbe?.validatedAt,
            now: now
        )
    }

    func currentCLIDisplaySidebarLimitSummary(now: Date = .now) -> SidebarLimitSummary? {
        if let liveSummary = currentCLISidebarLimitSummary(now: now), liveSummary.hasLimitData {
            return liveSummary
        }

        guard let account = currentCLIReferenceAccount() else {
            return nil
        }

        return sidebarLimitSummary(for: account, now: now)
    }

    func sidebarLimitSummary(for account: StoredAccount, now: Date = .now) -> SidebarLimitSummary? {
        let useLiveProbe = isCurrentCLIAccount(account) && currentCLIProbe?.fingerprint == account.authFingerprint
        if useLiveProbe {
            return CodexAccountsPresentationPolicy.sidebarLimitSummary(
                primary: currentCLIProbe?.rateLimit,
                byLimitId: currentCLIProbe?.rateLimitsByLimitId,
                observedAt: currentCLIProbe?.validatedAt,
                now: now
            )
        }

        return CodexAccountsPresentationPolicy.sidebarLimitSummary(
            primary: account.lastRateLimit,
            byLimitId: account.lastRateLimitsByLimitId,
            observedAt: account.lastValidatedAt,
            now: now
        )
    }

    func currentCLIProbeHasExpiredReset(now: Date = .now) -> Bool {
        guard let probe = currentCLIProbe else {
            return false
        }

        return CodexAccountsPresentationPolicy.currentProbeHasExpiredReset(probe, now: now)
    }

    func storedRateLimitSummary(for account: StoredAccount) -> String? {
        CodexAccountsPresentationPolicy.storedRateLimitSummary(
            primary: account.lastRateLimit,
            byLimitId: account.lastRateLimitsByLimitId,
            observedAt: account.lastValidatedAt
        )
    }

    func remainingPercent(for account: StoredAccount) -> Int? {
        sidebarLimitSummary(for: account)?.fiveHourRemainingPercent
    }

    func currentCLIValidatedAt() -> Date? {
        currentCLIProbe?.validatedAt ?? currentCLIReferenceAccount()?.lastValidatedAt
    }

    func claudeValidatedAt(for account: ClaudeStoredAccount? = nil) -> Date? {
        if let account {
            return account.lastValidatedAt
        }
        return currentClaudeValidatedAt ?? currentClaudeReferenceAccount()?.lastValidatedAt
    }

    func localizedPlan(_ value: String) -> String {
        switch value.lowercased() {
        case "pro":
            return L10n.tr("plan.pro")
        case "plus":
            return L10n.tr("plan.plus")
        case "free":
            return L10n.tr("plan.free")
        case "unknown":
            return L10n.tr("plan.unknown")
        default:
            return value
        }
    }

    func localizedClaudePlan(_ value: String?) -> String {
        switch value?.lowercased() {
        case "max":
            return "Claude Max"
        case "pro":
            return "Claude Pro"
        case "team":
            return "Claude Team"
        case "enterprise":
            return "Claude Enterprise"
        case "console":
            return "Claude Console"
        case "claude.ai":
            return L10n.tr("plan.claude.subscription")
        case "unknown", nil:
            return L10n.tr("plan.unknown")
        default:
            return value ?? L10n.tr("plan.unknown")
        }
    }

    private func titleForStoredAccount(_ account: StoredAccount?, probe: CurrentCLIProbe?) -> String {
        if let account {
            return account.label
        }
        return probe?.email ?? L10n.tr("account.saved")
    }

    private func titleForExternalAuth(_ account: StoredAccount?, probe: CurrentCLIProbe?) -> String {
        if let probe {
            return probe.email
        }
        if let account {
            return account.label
        }
        return currentCLIState.accountId ?? L10n.tr("account.external_auth")
    }

    private func claudeSubtitle(account: ClaudeStoredAccount?, status: ClaudeAuthStatus?) -> String? {
        if let account, account.label.caseInsensitiveCompare(account.email) != .orderedSame {
            return account.email
        }

        if let status, let subscriptionType = status.subscriptionType {
            return localizedClaudePlan(subscriptionType)
        }

        if let account {
            return localizedClaudePlan(account.subscriptionType)
        }

        return nil
    }

    private func claudeNote(account: ClaudeStoredAccount?) -> String? {
        if let currentClaudeError {
            return currentClaudeError
        }

        if let currentClaudeBridgeError {
            return currentClaudeBridgeError
        }

        if let account {
            if account.status == .needsReauth {
                return L10n.tr("claude.reauth_needed")
            }
            if let orgName = account.orgName, !orgName.isEmpty {
                return L10n.tr("claude.org_limits_note", orgName)
            }
        }

        return L10n.tr("claude.limits_note")
    }

    private func noteForStoredAccount(_ account: StoredAccount?) -> String? {
        if let probeError = currentCLIProbeError {
            return CodexSessionPresentation.probeNote(for: probeError)
        }
        if currentCLIProbe == nil {
            return isRefreshingCurrentCLIProbe ? L10n.tr("busy.refreshing_live_limits") : L10n.tr("limits.empty.account.subtitle")
        }
        guard let account else {
            return nil
        }
        if account.lastRateLimit == nil {
            return L10n.tr("limits.empty.account.subtitle")
        }
        if account.status == .limitReached {
            return account.statusMessage ?? L10n.tr("account.limit_reached")
        }
        if account.status == .needsReauth {
            return L10n.tr("account.needs_login")
        }
        if account.status == .validationFailed {
            return L10n.tr("account.error")
        }
        return nil
    }

    private func noteForExternalAuth(_ account: StoredAccount?) -> String? {
        if let probeError = currentCLIProbeError {
            return CodexSessionPresentation.probeNote(for: probeError)
        }
        if isRefreshingCurrentCLIProbe && currentCLIProbe == nil {
            return L10n.tr("busy.refreshing_live_limits")
        }
        if currentCLIProbe == nil {
            return L10n.tr("limits.empty.account.subtitle")
        }
        if account != nil {
            return nil
        }
        return L10n.tr("cli.import_current_note")
    }

}
