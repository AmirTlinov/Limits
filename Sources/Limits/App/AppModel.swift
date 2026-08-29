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
    @Published private(set) var accountsAccess: AccountsRepositoryAccess = .readWrite
    @Published private(set) var codexUsageData = CodexUsageRepositorySnapshot(
        accountUsage: [:],
        dailyUsage: [],
        limitObservations: [:],
        latestLimits: [:],
        rateCardRevisions: []
    )
    @Published private(set) var codexAnalyticsSnapshots = CodexAnalyticsSnapshotSet.empty()
    @Published private(set) var codexUsagePeriod: CodexUsagePeriod = .currentWeek
    @Published private(set) var codexPriceChange: OpenAIPriceChange?
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
    @Published private(set) var persistedStateLoaded = false

    private let accountsRepository: AccountsRepository
    private let usageCoordinator: CodexUsageCoordinator
    private let codexSessionCoordinator: CodexSessionCoordinator
    private let claudeSessionCoordinator: ClaudeSessionCoordinator
    private let backgroundRefreshInterval: TimeInterval = 300
    private let presentationTickInterval: TimeInterval = 30
    private let widgetSnapshotPublisher: LimitsWidgetSnapshotPublisher
    private let isIsolatedRuntime: Bool
    private var backgroundRefreshTask: Task<Void, Never>?
    private var presentationClockTask: Task<Void, Never>?
    private var bootstrapTask: Task<Void, Never>?
    private var currentValuesRefreshTask: Task<Void, Never>?
    private var currentValuesRefreshID: UUID?
    private var codexRateCard = OpenAIPricingCatalog.bundledRevision
    private var customCodexUsageWindow: CodexUsageWindow?
    private var selectedCodexAccountID: UUID?
    private var codexPresentationRefreshDepth = 0

    var codexInsights: CodexInsightsSnapshot {
        codexAnalyticsSnapshots[codexUsagePeriod]
    }

    var currentCustomCodexUsageWindow: CodexUsageWindow {
        codexAnalyticsSnapshots.custom.window
    }

    var canMutateDomain: Bool { accountsAccess == .readWrite }

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
        usageCoordinator = dependencies.usageCoordinator
        codexSessionCoordinator = dependencies.codexCoordinator
        claudeSessionCoordinator = dependencies.claudeCoordinator
        widgetSnapshotPublisher = dependencies.widgetPublisher
        isIsolatedRuntime = dependencies.isolated
        bootstrapTask = Task { @MainActor [weak self] in
            await self?.performBootstrap()
        }
        startPresentationClockLoop()
        if !isIsolatedRuntime {
            startBackgroundRefreshLoop()
        }
    }

    deinit {
        backgroundRefreshTask?.cancel()
        presentationClockTask?.cancel()
        bootstrapTask?.cancel()
        currentValuesRefreshTask?.cancel()
    }

    private func performBootstrap() async {
        defer { publishWidgetSnapshotIfPossible() }

        do {
            try await loadPersistedState()
            guard persistedStateLoaded else { return }
            guard canMutateDomain else { return }
            await refreshCurrentValues()

            if accounts.isEmpty, case .external = currentCLIState.source {
                try await importCurrentCLIAuthNow()
                await refreshCurrentValues()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshForPresentation() async {
        if let bootstrapTask {
            await bootstrapTask.value
        }
        guard persistedStateLoaded else { return }
        guard canMutateDomain else { return }
        await refreshCurrentValues()
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
        } else if case .readOnlyRecovery(let reason) = snapshot.access {
            setNotice(AccountsRepositoryError.readOnlyRecovery(reason: reason).localizedDescription, provider: .codex)
        }
        applyRepositorySnapshot(snapshot)
        if case .readOnlyRecovery(reason: .accountsSchema(schemaVersion: _)) = snapshot.access {
            persistedStateLoaded = true
            return
        }
        let cached = try await usageCoordinator.cachedData()
        codexUsageData = cached.0
        codexRateCard = cached.1
        rebuildCodexInsights()
        if snapshot.access == .readWrite {
            await usageCoordinator.startLocalHistoryWatcher()
        }
        persistedStateLoaded = true
    }

    private func applyRepositorySnapshot(_ snapshot: AccountsRepositorySnapshot) {
        accountsAccess = snapshot.access
        accounts = snapshot.state.accounts
        claudeAccounts = snapshot.state.claudeAccounts
        providerCatalog = ProviderCatalogSnapshot(
            savedClaudeCount: claudeAccounts.count,
            claudeSource: currentClaudeState.source
        )
        rebuildCodexInsights()
    }

    private func rebuildCodexInsights() {
        codexAnalyticsSnapshots = CodexUsagePresentation.makeSnapshotSet(
            accounts: accounts,
            repository: codexUsageData,
            rateCard: codexRateCard,
            priceChange: codexPriceChange,
            customWindow: customCodexUsageWindow,
            now: presentationNow
        )
    }

    func selectCodexUsagePeriod(_ period: CodexUsagePeriod) {
        codexUsagePeriod = period
    }

    func selectCustomCodexUsageWindow(_ window: CodexUsageWindow) {
        customCodexUsageWindow = window
        rebuildCodexInsights()
        codexUsagePeriod = .custom
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
        guard canMutateDomain else { return }
        defer { publishWidgetSnapshotIfPossible() }
        let observedAt = Date()
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
            await recordCurrentCodexIdentity(
                accountID: observation.accountID,
                fingerprint: observation.authFingerprint,
                observedAt: observedAt,
                transition: .observed
            )
        } catch {
            currentCLIState = CurrentCLIState(source: .unreadable, authFingerprint: nil, accountId: nil, authMode: nil)
            currentCLIProbe = nil
            currentCLIProbeError = nil
            errorMessage = error.localizedDescription
            await recordCurrentCodexIdentity(
                accountID: nil,
                fingerprint: nil,
                observedAt: observedAt,
                transition: .observed
            )
        }
    }

    private func recordCurrentCodexIdentity(
        accountID: String?,
        fingerprint: String?,
        observedAt: Date,
        transition: CodexAuthIdentityTransition
    ) async {
        do {
            try await usageCoordinator.observeCurrentSession(
                accountID: accountID,
                fingerprint: fingerprint,
                observedAt: observedAt,
                transition: transition
            )
        } catch {
            setNotice(error.localizedDescription, provider: .codex)
        }
    }

    func refreshCurrentCLIProbe() async {
        guard canMutateDomain else { return }
        defer { publishWidgetSnapshotIfPossible() }
        if isCurrentCLIAuthMissing() || isCurrentCLIAuthUnreadable() || currentCLIState.authFingerprint == nil {
            currentCLIProbe = nil
            currentCLIProbeError = nil
        }

        codexPresentationRefreshDepth += 1
        isRefreshingCurrentCLIProbe = true
        defer {
            codexPresentationRefreshDepth -= 1
            isRefreshingCurrentCLIProbe = codexPresentationRefreshDepth > 0
        }

        do {
            let currentID = currentCodexAccountIDForRefreshExclusion()
            let output = try await usageCoordinator.refresh(
                currentAccountLocalID: currentID,
                selectedAccountLocalID: selectedCodexAccountID,
                forceAccountIDs: [],
                now: Date()
            )
            applyUsageCoordinatorSnapshot(output)
            if let fingerprint = output.currentValidation?.authFingerprint,
               fingerprint != currentCLIState.authFingerprint {
                await refreshCurrentCLIState()
            }
        } catch {
            currentCLIProbeError = error.localizedDescription
        }
    }

    func selectCodexAccountForUsageRefresh(_ accountID: UUID?) {
        selectedCodexAccountID = accountID
    }

    func codexInsights(for account: StoredAccount) -> CodexAccountInsights? {
        let id = account.accountId ?? "local:\(account.id.uuidString)"
        return codexInsights.accounts.first { $0.id == id }
    }

    func currentCodexForecastText(now: Date = .now) -> String? {
        if let account = currentCLIReferenceAccount(), codexAccountIssue(for: account) != nil {
            return nil
        }
        return CodexAnalyticsSurfacePresentation.trayForecast(
            from: codexInsights,
            currentAccountID: currentCLIReferenceAccount()?.accountId,
            now: now
        )
    }

    func dismissCodexPriceChange() {
        codexPriceChange = nil
        rebuildCodexInsights()
    }

    func clearCodexStatistics() async {
        await runBusy(provider: .codex, L10n.tr("insights.settings.clearing")) { [self] in
            codexUsageData = try await usageCoordinator.clearStatistics()
            codexPriceChange = nil
            rebuildCodexInsights()
            publishWidgetSnapshotIfPossible()
        }
    }

    func reimportCodexHistory() async {
        await runBusy(provider: .codex, L10n.tr("insights.settings.importing")) { [self] in
            codexUsageData = try await usageCoordinator.reimportHistory()
            rebuildCodexInsights()
            publishWidgetSnapshotIfPossible()
        }
    }

    private func applyUsageCoordinatorSnapshot(_ output: CodexUsageCoordinatorSnapshot) {
        applyRepositorySnapshot(output.accounts)
        codexUsageData = output.usage
        codexRateCard = output.rateCard
        if let priceChange = output.priceChange { codexPriceChange = priceChange }
        synchronizeCurrentCLIProbe(validation: output.currentValidation)
        rebuildCodexInsights()
    }

    private func synchronizeCurrentCLIProbe(validation: AccountValidationResult?) {
        guard let account = currentCLIReferenceAccount(), let accountID = account.accountId else { return }
        let latest = codexUsageData.latestLimits[accountID]
        let endpointError = codexUsageData.endpointStatuses[accountID]?[.limits]?.errorMessage
        let validatedAt = validation.map { _ in Date() } ?? account.lastValidatedAt ?? latest?.observedAt ?? .distantPast
        currentCLIProbe = CurrentCLIProbe(
            fingerprint: validation?.authFingerprint ?? account.authFingerprint,
            email: validation?.email ?? account.email,
            planType: validation?.planType ?? account.planType,
            rateLimit: latest?.primary,
            rateLimitsByLimitId: latest?.byLimitID,
            validatedAt: validatedAt,
            rateLimitError: endpointError,
            rateLimitObservedAt: latest?.limitsObservedAt,
            subscriptionPeriod: validation?.subscriptionPeriod ?? account.subscriptionPeriod
        )
        currentCLIProbeError = endpointError
    }

    func refreshCurrentCLIPanel() async {
        await refreshCurrentCLIState()
        await refreshCurrentCLIProbe()
    }

    func refreshCurrentClaudeState() async {
        guard canMutateDomain else { return }
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
            await self.refreshCurrentCLIProbe()
        }
    }

    func importCurrentCLIAuth() async {
        await runBusy(provider: .codex, L10n.tr("busy.importing_current_cli")) { [self] in
            try await self.importCurrentCLIAuthNow()
            await self.refreshCurrentCLIState()
            await self.refreshCurrentCLIProbe()
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
                let switched = try await self.codexSessionCoordinator.switchAccount(account, authData: authData) { result in
                    try await self.persistValidatedAccount(result, forAccountID: account.id)
                }
                await self.recordCurrentCodexIdentity(
                    accountID: switched.validation.identity.accountId,
                    fingerprint: switched.validation.authFingerprint,
                    observedAt: Date(),
                    transition: .exact
                )
                await self.refreshCurrentCLIState()
                await self.refreshCurrentCLIProbe()
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
            await self.refreshCurrentCLIProbe()
        }
    }

    func renameAccount(_ account: StoredAccount, to proposedLabel: String) async {
        await renameAccount(
            provider: .codex,
            accountID: account.id,
            to: proposedLabel
        )
    }

    func renameAccount(_ account: ClaudeStoredAccount, to proposedLabel: String) async {
        await renameAccount(
            provider: .claude,
            accountID: account.id,
            to: proposedLabel
        )
    }

    private func renameAccount(
        provider: ProviderKind,
        accountID: UUID,
        to proposedLabel: String
    ) async {
        guard canMutateDomain else { return }
        let label = proposedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        defer { publishWidgetSnapshotIfPossible() }

        do {
            let snapshot = try await accountsRepository.renameAccount(
                provider: provider,
                accountID: accountID,
                label: label
            )
            applyRepositorySnapshot(snapshot)
            providerOperationStates[provider] = ProviderOperationState(
                notice: providerOperationStates[provider]?.notice
            )
            if provider == .codex {
                errorMessage = nil
            }
        } catch {
            providerOperationStates[provider] = ProviderOperationState(
                notice: providerOperationStates[provider]?.notice,
                error: error.localizedDescription
            )
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

    func refreshCurrentValues() async {
        guard canMutateDomain else { return }
        if let activeTask = currentValuesRefreshTask {
            await activeTask.value
            return
        }

        let refreshID = UUID()
        currentValuesRefreshID = refreshID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performCurrentValuesRefresh()
            self.finishCurrentValuesRefresh(id: refreshID)
        }
        currentValuesRefreshTask = task
        await task.value
    }

    private func finishCurrentValuesRefresh(id: UUID) {
        if currentValuesRefreshID == id {
            currentValuesRefreshTask = nil
            currentValuesRefreshID = nil
        }
    }

    private func performCurrentValuesRefresh() async {
        if !isProviderBusy(.codex) {
            await refreshCurrentCLIPanel()
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
        rebuildCodexInsights()
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
        await refreshCurrentValues()
    }

    private func currentCodexAccountIDForRefreshExclusion() -> UUID? {
        currentCLIReferenceAccount()?.id
    }

    func deleteAccount(_ account: StoredAccount) async {
        await runBusy(provider: .codex, L10n.tr("busy.deleting", account.label)) { [self] in
            let snapshot = try await self.usageCoordinator.deleteAccount(provider: .codex, accountID: account.id)
            self.applyRepositorySnapshot(snapshot)
            await self.refreshCurrentCLIState()
            await self.refreshCurrentCLIProbe()
        }
    }

    func deleteClaudeAccount(_ account: ClaudeStoredAccount) async {
        await runBusy(provider: .claude, L10n.tr("busy.deleting", account.label)) { [self] in
            let snapshot = try await self.usageCoordinator.deleteAccount(provider: .claude, accountID: account.id)
            self.applyRepositorySnapshot(snapshot)
            await self.refreshCurrentClaudeState()
        }
    }

    func requestDeleteAccount(_ account: StoredAccount) {
        guard canMutateDomain else { return }
        pendingCredentialDeletion = .codex(account)
    }

    func requestDeleteClaudeAccount(_ account: ClaudeStoredAccount) {
        guard canMutateDomain else { return }
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
                title: account?.label ?? currentClaudeStatus?.email ?? "Claude Code",
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

    /// The rail needs more than the widget snapshot carries: every Codex account rather than
    /// just the active one, and Claude's last known numbers when its bridge snapshot has aged out.
    func usageRailInputs(now: Date = .now) -> [UsageRailProviderInput] {
        let byID: [ProviderKind: UsageRailProviderInput] = [
            .codex: codexRailInput(now: now),
            .claude: claudeRailInput(now: now),
        ]
        return providerCatalog.providers.compactMap { byID[$0] }
    }

    private func codexRailInput(now: Date) -> UsageRailProviderInput {
        let currentAccount = currentCLIReferenceAccount()
        let ordered = accounts.sorted { lhs, rhs in
            if isCurrentCLIAccount(lhs) != isCurrentCLIAccount(rhs) {
                return isCurrentCLIAccount(lhs)
            }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }

        var inputs = ordered.map { account in
            UsageRailAccountInput(
                id: account.id.uuidString,
                title: account.label,
                sections: railSections(for: account, now: now)
            )
        }

        let overview = currentCLIOverview()
        let currentSections = currentCLIDisplayRateLimitSections(now: now)

        // An externally authorized session has no stored record, so surface it on its own.
        if currentAccount == nil {
            inputs.insert(
                UsageRailAccountInput(
                    id: "codex.current",
                    title: overview.title,
                    sections: currentSections
                ),
                at: 0
            )
        }

        let observedAt = currentCLILimitsObservedAt()
        return UsageRailProviderInput(
            id: .codex,
            accounts: inputs,
            status: widgetCodexStatus(
                limits: WidgetPresentationPolicy.limitSnapshots(from: currentSections, now: now)
            ),
            note: overview.note ?? currentCLIProbeError,
            observedAt: observedAt,
            isStale: !LimitsFreshnessPolicy.isFresh(observedAt: observedAt, at: now)
        )
    }

    /// Like `rateLimitSections(for:)` but keeps the last known numbers for accounts whose
    /// snapshot has aged out, so every signed-in account still gets a line on the rail.
    private func railSections(for account: StoredAccount, now: Date) -> [RateLimitDisplaySection] {
        let fresh = rateLimitSections(for: account, now: now)
        guard fresh.isEmpty else { return fresh }
        let snapshot = storedLimits(for: account)
        return CodexAccountsPresentationPolicy.lastKnownRateLimitSections(
            primary: snapshot?.primary,
            byLimitId: snapshot?.byLimitID,
            now: now
        )
    }

    private func claudeRailInput(now: Date) -> UsageRailProviderInput {
        let overview = currentClaudeOverview()
        let fresh = currentClaudeLiveRateLimitSections(now: now)
        let sections = fresh.isEmpty
            ? ClaudeLivePresentation.lastKnownRateLimitSections(evidence: currentClaudeLiveEvidence)
            : fresh
        let observedAt = currentClaudeLiveEvidence?.snapshotAt

        return UsageRailProviderInput(
            id: .claude,
            accounts: [
                UsageRailAccountInput(
                    id: "claude.current",
                    title: overview.title,
                    sections: sections
                )
            ],
            status: widgetClaudeStatus(
                limits: WidgetPresentationPolicy.limitSnapshots(from: fresh, now: now)
            ),
            note: overview.note ?? currentClaudeBridgeError ?? currentClaudeError,
            observedAt: observedAt,
            isStale: fresh.isEmpty && !sections.isEmpty
        )
    }

    func makeWidgetSnapshot(now: Date = .now) -> LimitsWidgetSnapshot {
        let codexOverview = currentCLIOverview()
        let codexLimits = WidgetPresentationPolicy.limitSnapshots(from: currentCLIDisplayRateLimitSections(now: now), now: now)
        let codexObservedAt = currentCLILimitsObservedAt()
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
        return LimitsWidgetSnapshot(
            generatedAt: now,
            providers: providers,
            codexAnalytics: CodexAnalyticsSurfacePresentation.widgetSummary(
                from: codexAnalyticsSnapshots.currentWeek
            )
        )
    }

    func storedCodexAccountHasFreshCompactLimits(_ account: StoredAccount, now: Date = .now) -> Bool {
        let snapshot = storedLimits(for: account)
        let limits = WidgetPresentationPolicy.limitSnapshots(
            from: CodexAccountsPresentationPolicy.storedRateLimitSections(
                primary: snapshot?.primary,
                byLimitId: snapshot?.byLimitID,
                observedAt: snapshot?.limitsObservedAt,
                now: now
            ),
            now: now
        )
        guard limits.contains(where: { $0.remainingPercent != nil }) else { return false }
        guard
            let observedAt = snapshot?.limitsObservedAt,
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
                guard let account = currentCLIReferenceAccount() else { return true }
                return account.status == .ok && !codexAccountIsSpendBlocked(account)
            }()
            let storedAvailable = accounts.filter { account in
                !isCurrentCLIAccount(account)
                    && account.status == .ok
                    && !codexAccountIsSpendBlocked(account)
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

        let existingAccount = existingIndex.map { accounts[$0] }
        let recordID: UUID
        let label: String
        let createdAt: Date

        if let existingAccount {
            recordID = existingAccount.id
            label = existingAccount.label
            createdAt = existingAccount.createdAt
        } else {
            recordID = UUID()
            label = makeUniqueLabel(base: preferredLabel)
            createdAt = Date()
        }

        let now = Date()
        let updatedRecord: StoredAccount
        if let existingAccount {
            updatedRecord = CodexAccountValidationPolicy.applying(result, to: existingAccount, observedAt: now)
        } else {
            updatedRecord = CodexAccountValidationPolicy.makeAccount(
                id: recordID,
                label: label,
                createdAt: createdAt,
                from: result,
                observedAt: now
            )
        }

        let snapshot: AccountsRepositorySnapshot
        if let existingAccount, existingAccount.authFingerprint == result.authFingerprint {
            snapshot = try await accountsRepository.updateCodexAccount(updatedRecord)
        } else {
            snapshot = try await accountsRepository.saveCodexAccount(updatedRecord, credential: result.authData)
        }
        applyRepositorySnapshot(snapshot)
        codexUsageData = try await usageCoordinator.ingest(result, observedAt: now)
        synchronizeCurrentCLIProbe(validation: result)
        rebuildCodexInsights()
    }

    private func persistValidatedAccount(_ result: AccountValidationResult, forAccountID id: UUID) async throws {
        guard let account = accounts.first(where: { $0.id == id }) else {
            return
        }

        let now = Date()
        let stored = CodexAccountValidationPolicy.applying(result, to: account, observedAt: now)
        let snapshot: AccountsRepositorySnapshot
        if result.authFingerprint == account.authFingerprint {
            snapshot = try await accountsRepository.updateCodexAccount(stored)
        } else {
            snapshot = try await accountsRepository.saveCodexAccount(stored, credential: result.authData)
        }
        applyRepositorySnapshot(snapshot)
        codexUsageData = try await usageCoordinator.ingest(result, observedAt: now)
        synchronizeCurrentCLIProbe(validation: result)
        rebuildCodexInsights()
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
        guard canMutateDomain else { return }
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

        let snapshot = storedLimits(for: account)
        return CodexAccountsPresentationPolicy.storedRateLimitSections(
            primary: snapshot?.primary,
            byLimitId: snapshot?.byLimitID,
            observedAt: snapshot?.limitsObservedAt,
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

        let snapshot = storedLimits(for: account)
        return CodexAccountsPresentationPolicy.storedRateLimitSections(
            primary: snapshot?.primary,
            byLimitId: snapshot?.byLimitID,
            observedAt: snapshot?.limitsObservedAt,
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

    func sidebarLimitSummary(for account: StoredAccount, now: Date = .now) -> SidebarLimitSummary? {
        let useLiveProbe = isCurrentCLIAccount(account) && currentCLIProbe?.fingerprint == account.authFingerprint
        if useLiveProbe {
            return CodexAccountsPresentationPolicy.sidebarLimitSummary(
                primary: currentCLIProbe?.rateLimit,
                byLimitId: currentCLIProbe?.rateLimitsByLimitId,
                observedAt: currentCLIProbe?.limitsObservedAt,
                now: now
            )
        }

        let snapshot = storedLimits(for: account)
        return CodexAccountsPresentationPolicy.sidebarLimitSummary(
            primary: snapshot?.primary,
            byLimitId: snapshot?.byLimitID,
            observedAt: snapshot?.limitsObservedAt,
            now: now
        )
    }

    func storedRateLimitSummary(for account: StoredAccount) -> String? {
        let snapshot = storedLimits(for: account)
        return CodexAccountsPresentationPolicy.storedRateLimitSummary(
            primary: snapshot?.primary,
            byLimitId: snapshot?.byLimitID,
            observedAt: snapshot?.limitsObservedAt
        )
    }

    func currentLastKnownRateLimitSummary() -> String? {
        currentCLIReferenceAccount().flatMap(storedRateLimitSummary)
    }

    func remainingPercent(for account: StoredAccount) -> Int? {
        sidebarLimitSummary(for: account)?.fiveHourRemainingPercent
    }

    func currentCLILimitsObservedAt() -> Date? {
        currentCLIProbe?.limitsObservedAt ?? currentCLIReferenceAccount().flatMap { storedLimits(for: $0)?.limitsObservedAt }
    }

    func currentChatGPTPlanPresentation() -> ChatGPTPlanPresentation? {
        let planType = currentCLIProbe?.planType ?? currentCLIReferenceAccount()?.planType
        guard let planType, planType.caseInsensitiveCompare("unknown") != .orderedSame else { return nil }
        return ChatGPTSubscriptionPresentationPolicy.plan(for: planType)
    }

    func chatGPTPlanPresentation(for account: StoredAccount) -> ChatGPTPlanPresentation {
        ChatGPTSubscriptionPresentationPolicy.plan(for: account.planType)
    }

    func currentChatGPTSubscriptionCycle(now: Date = .now) -> ChatGPTSubscriptionCyclePresentation? {
        ChatGPTSubscriptionPresentationPolicy.cycle(
            for: currentCLIProbe?.subscriptionPeriod ?? currentCLIReferenceAccount()?.subscriptionPeriod,
            now: now
        )
    }

    func chatGPTSubscriptionCycle(for account: StoredAccount, now: Date = .now) -> ChatGPTSubscriptionCyclePresentation? {
        ChatGPTSubscriptionPresentationPolicy.cycle(for: account.subscriptionPeriod, now: now)
    }

    func codexAccountIssue(for account: StoredAccount) -> CodexAccountIssuePresentation? {
        CodexAccountIssuePresentationPolicy.presentation(for: account)
    }

    func claudeValidatedAt(for account: ClaudeStoredAccount? = nil) -> Date? {
        if let account {
            return account.lastValidatedAt
        }
        return currentClaudeValidatedAt ?? currentClaudeReferenceAccount()?.lastValidatedAt
    }

    func localizedPlan(_ value: String) -> String {
        ChatGPTSubscriptionPresentationPolicy.plan(for: value).title
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
        if let account {
            return account.label
        }
        if let probe {
            return probe.email
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
        if storedLimits(for: account)?.primary == nil,
           storedLimits(for: account)?.byLimitID?.isEmpty != false {
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

    private func storedLimits(for account: StoredAccount) -> CodexRateLimitsSnapshot? {
        account.accountId.flatMap { codexUsageData.latestLimits[$0] }
    }

    func codexAccountIsSpendBlocked(_ account: StoredAccount) -> Bool {
        guard let limits = storedLimits(for: account) else { return false }
        let snapshots = limits.byLimitID.map { Array($0.values) } ?? [limits.primary].compactMap { $0 }
        return snapshots.contains {
            $0.spendControlReached == true || $0.individualLimit?.remainingPercent == 0
        }
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
