import AppKit
import Foundation
import LimitsShared

@MainActor
final class AppModel: ObservableObject {
    struct CurrentCLIState {
        enum Source {
            case missing
            case stored(UUID)
            case external(String?)
            case unreadable
        }

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

    struct CurrentCLIProbe {
        let fingerprint: String
        let email: String
        let planType: String
        let rateLimit: RateLimitSnapshotModel?
        let rateLimitsByLimitId: [String: RateLimitSnapshotModel]?
        let validatedAt: Date
    }

    struct CurrentClaudeState {
        enum Source: Equatable {
            case notInstalled
            case loggedOut
            case stored(UUID)
            case external(String?)
            case unreadable
        }

        var source: Source = .notInstalled
        var authFingerprint: String?
    }

    struct CurrentClaudeOverview {
        let title: String
        let subtitle: String?
        let note: String?
    }

    struct SidebarLimitSummary: Hashable {
        let fiveHourRemainingPercent: Int?
        let weeklyRemainingPercent: Int?
        let nextResetDate: Date?

        var hasLimitData: Bool {
            fiveHourRemainingPercent != nil || weeklyRemainingPercent != nil
        }

        var limitSortScore: Int {
            [fiveHourRemainingPercent, weeklyRemainingPercent]
                .compactMap(\.self)
                .reduce(0, +)
        }

        func compactLimitText() -> String? {
            var parts: [String] = []

            if let fiveHourRemainingPercent {
                parts.append("\(L10n.windowLabel(minutes: 300, fallback: "5h")) \(fiveHourRemainingPercent)%")
            }

            if let weeklyRemainingPercent {
                parts.append("\(L10n.durationLabel(minutes: 10_080)) \(weeklyRemainingPercent)%")
            }

            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        func compactResetText(now: Date = .now) -> String? {
            nextResetDate.map { RateLimitResetFormatter.compactText(for: $0, now: now) }
        }
    }

    @Published private(set) var accounts: [StoredAccount] = []
    @Published private(set) var claudeAccounts: [ClaudeStoredAccount] = []
    @Published private(set) var currentCLIState = CurrentCLIState()
    @Published private(set) var currentCLIProbe: CurrentCLIProbe?
    @Published private(set) var isRefreshingCurrentCLIProbe = false
    @Published private(set) var currentClaudeState = CurrentClaudeState()
    @Published private(set) var currentClaudeStatus: ClaudeAuthStatus?
    @Published private(set) var currentClaudeValidatedAt: Date?
    @Published private(set) var currentClaudeLivePayload: ClaudeStatuslineBridgePayload?
    @Published private(set) var currentClaudeLiveBridgeStatus = ClaudeStatuslineBridgeStatus(installed: false, hasSnapshot: false, preservingOriginalStatusLine: false)
    @Published var isBusy = false
    @Published var busyMessage: String?
    @Published var errorMessage: String?
    @Published var currentCLIProbeError: String?
    @Published var currentClaudeError: String?
    @Published var currentClaudeBridgeError: String?
    @Published private(set) var migrationNotice: String?
    @Published private(set) var presentationNow = Date()

    private let persistence = AccountsPersistence()
    private let vault = KeychainAuthVault()
    private let globalAuthService = GlobalCodexAuthService()
    private let codexAccountService = CodexAccountService()
    private let globalClaudeCredentialService = GlobalClaudeCredentialService()
    private let claudeAuthStatusService = ClaudeAuthStatusService()
    private let claudeStatuslineBridgeService = ClaudeStatuslineBridgeService()
    private let currentCLIProbeTTL: TimeInterval = 300
    private let backgroundRefreshInterval: TimeInterval = 300
    private let presentationTickInterval: TimeInterval = 30
    private let currentCLIExpiredResetRetryInterval: TimeInterval = 300
    private let storedCodexAutoRefreshInterval: TimeInterval = 60
    private let widgetSnapshotPublisher = LimitsWidgetSnapshotPublisher()
    private let storedCodexAutoRefreshRetryInterval: TimeInterval = 1_800
    private var backgroundRefreshTask: Task<Void, Never>?
    private var presentationClockTask: Task<Void, Never>?
    private var storedCodexAutoRefreshTask: Task<Void, Never>?
    private var lastStoredCodexAutoRefreshAttempt: [UUID: Date] = [:]
    private var lastCurrentCLIExpiredResetRefreshAttempt: Date?
    private var isRefreshingStoredCodexAccount = false
    private var persistedStateLoaded = false
    private var retiredCredentials: [RetiredCredential] = []

    func invalidateLocalizedText() {
        objectWillChange.send()
    }

    init() {
        loadPersistedState()
        Task { await bootstrap() }
        startPresentationClockLoop()
        startBackgroundRefreshLoop()
        startStoredCodexAutoRefreshLoop()
    }

    deinit {
        backgroundRefreshTask?.cancel()
        presentationClockTask?.cancel()
        storedCodexAutoRefreshTask?.cancel()
    }

    func bootstrap() async {
        defer { publishWidgetSnapshotIfPossible() }
        guard persistedStateLoaded else {
            return
        }

        do {
            await refreshCurrentCLIState()
            await refreshCurrentClaudeState()

            if accounts.isEmpty, globalAuthService.hasGlobalAuth() {
                try await importCurrentCLIAuthNow()
                await refreshCurrentCLIState()
            }
            await refreshCurrentCLIProbe(force: false)
            await refreshOneStaleStoredCodexAccountInBackground()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadPersistedState() {
        do {
            let originalData = try persistence.loadData()
            let state = try originalData.map { try JSONDecoder.limits.decode(PersistedState.self, from: $0) }
                ?? PersistedState(accounts: [])
            let currentCodexFingerprint = (try? globalAuthService.readGlobalAuth())
                .map { CodexAuthBlob.fingerprint(for: $0) }
            let migration = PersistedStateMigrator.migrate(
                state,
                currentCodexFingerprint: currentCodexFingerprint,
                currentClaudeFingerprint: nil
            )

            if migration.receipt.didChange {
                if let originalData {
                    try persistence.backupBeforeV2Migration(originalData)
                }
                try persistence.save(migration.state)
                if migration.receipt.retiredCredentialCount > 0 {
                    migrationNotice = L10n.tr("migration.duplicates_merged", migration.receipt.retiredCredentialCount)
                }
            }

            accounts = migration.state.accounts.sorted(by: { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending })
            claudeAccounts = migration.state.claudeAccounts.sorted(by: { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending })
            retiredCredentials = migration.state.retiredCredentials
            try purgeExpiredRetiredCredentials()
            persistedStateLoaded = true
        } catch {
            errorMessage = error.localizedDescription
            persistedStateLoaded = false
        }
    }

    func refreshCurrentCLIState() async {
        defer { publishWidgetSnapshotIfPossible() }
        do {
            guard globalAuthService.hasGlobalAuth() else {
                currentCLIState = CurrentCLIState(source: .missing, authFingerprint: nil, accountId: nil, authMode: nil)
                currentCLIProbe = nil
                currentCLIProbeError = nil
                return
            }

            let data = try globalAuthService.readGlobalAuth()
            let identity = try CodexAuthBlob.identity(from: data)
            let fingerprint = CodexAuthBlob.fingerprint(for: data)

            if let matched = Self.resolveStoredAccountMatch(identity: identity, fingerprint: fingerprint, accounts: accounts) {
                currentCLIState = CurrentCLIState(
                    source: .stored(matched.id),
                    authFingerprint: fingerprint,
                    accountId: identity.accountId,
                    authMode: identity.authMode
                )
            } else {
                currentCLIState = CurrentCLIState(
                    source: .external(identity.accountId),
                    authFingerprint: fingerprint,
                    accountId: identity.accountId,
                    authMode: identity.authMode
                )
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
        guard globalAuthService.hasGlobalAuth() else {
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
        if !force, let probe = currentCLIProbe, Self.currentCLIProbeCanBeReused(
            probe,
            expectedFingerprint: fingerprint,
            now: now,
            ttl: currentCLIProbeTTL
        ) {
            return
        }

        guard !isRefreshingCurrentCLIProbe else {
            return
        }

        isRefreshingCurrentCLIProbe = true
        defer { isRefreshingCurrentCLIProbe = false }

        do {
            let authData = try globalAuthService.readGlobalAuth()
            let result = try await codexAccountService.validate(authData: authData)
            currentCLIProbe = CurrentCLIProbe(
                fingerprint: result.authFingerprint,
                email: result.email,
                planType: result.planType,
                rateLimit: result.rateLimit,
                rateLimitsByLimitId: result.rateLimitsByLimitId,
                validatedAt: now
            )
            currentCLIProbeError = nil

            do {
                if result.authFingerprint != fingerprint {
                    try globalAuthService.writeGlobalAuth(result.authData)
                }
                try persistValidatedCurrentCLIAccountIfKnown(result)
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
        guard claudeAuthStatusService.isInstalled() else {
            currentClaudeState = CurrentClaudeState(source: .notInstalled, authFingerprint: nil)
            currentClaudeStatus = nil
            currentClaudeValidatedAt = nil
            currentClaudeLivePayload = nil
            currentClaudeLiveBridgeStatus = ClaudeStatuslineBridgeStatus(installed: false, hasSnapshot: false, preservingOriginalStatusLine: false)
            currentClaudeError = nil
            currentClaudeBridgeError = nil
            return
        }

        do {
            let status = try claudeAuthStatusService.readStatus()

            guard status.loggedIn else {
                currentClaudeState = CurrentClaudeState(source: .loggedOut, authFingerprint: nil)
                currentClaudeStatus = status
                currentClaudeValidatedAt = Date()
                currentClaudeError = nil
                refreshClaudeStatuslineBridgeState()
                return
            }

            if let matched = resolveCurrentClaudeAccount(status: status) {
                currentClaudeState = CurrentClaudeState(source: .stored(matched.id), authFingerprint: matched.authFingerprint)
            } else {
                currentClaudeState = CurrentClaudeState(source: .external(status.email), authFingerprint: nil)
            }

            currentClaudeStatus = status
            currentClaudeValidatedAt = Date()
            currentClaudeError = nil
            refreshClaudeStatuslineBridgeState()
        } catch {
            currentClaudeState = CurrentClaudeState(source: .unreadable, authFingerprint: nil)
            currentClaudeStatus = nil
            currentClaudeValidatedAt = nil
            currentClaudeLivePayload = nil
            currentClaudeError = error.localizedDescription
            refreshClaudeStatuslineBridgeState()
        }
    }

    func addAccount() async {
        await runBusy(L10n.tr("busy.signing_in")) { [self] in
            let result = try await self.codexAccountService.loginNewAccount { url in
                NSWorkspace.shared.open(url)
            }
            try self.upsertAccount(from: result, preferredLabel: result.email)
            await self.refreshCurrentCLIState()
            await self.refreshCurrentCLIProbe(force: true)
        }
    }

    func importCurrentCLIAuth() async {
        await runBusy(L10n.tr("busy.importing_current_cli")) { [self] in
            try await self.importCurrentCLIAuthNow()
            await self.refreshCurrentCLIState()
            await self.refreshCurrentCLIProbe(force: true)
        }
    }

    func importCurrentClaudeAuth() async {
        await runBusy(L10n.tr("busy.importing_current_claude")) { [self] in
            try self.importCurrentClaudeAuthNow()
            await self.refreshCurrentClaudeState()
        }
    }

    func activateAccount(_ account: StoredAccount) async {
        await runBusy(L10n.tr("busy.switching_global_auth")) { [self] in
            let authData = try self.vault.read(account: account.keychainAccount)
            try self.globalAuthService.writeGlobalAuth(authData)
            await self.refreshCurrentCLIState()
            await self.refreshCurrentCLIProbe(force: true)
        }
    }

    func reauthenticateAccount(_ account: StoredAccount) async {
        await runBusy(L10n.tr("busy.reauthenticating", account.label)) { [self] in
            let result = try await self.codexAccountService.loginNewAccount { url in
                NSWorkspace.shared.open(url)
            }
            try self.upsertAccount(from: result, preferredLabel: account.label, existingID: account.id)
            await self.refreshCurrentCLIState()
            await self.refreshCurrentCLIProbe(force: true)
        }
    }

    func activateClaudeAccount(_ account: ClaudeStoredAccount) async {
        await runBusy(L10n.tr("busy.switching_claude")) { [self] in
            let credential = try self.vault.read(account: account.keychainAccount)
            try self.globalClaudeCredentialService.writeGlobalCredential(credential)
            await self.refreshCurrentClaudeState()
            try self.refreshStoredClaudeMetadataIfNeeded()
        }
    }

    func refreshCurrentClaudeAccount() async {
        await runBusy(L10n.tr("busy.refreshing_claude")) { [self] in
            try self.refreshStoredClaudeMetadataIfNeeded()
            await self.refreshCurrentClaudeState()
        }
    }

    func installClaudeLiveLimitsBridge() async {
        guard !isBusy else { return }
        isBusy = true
        busyMessage = L10n.tr("busy.connecting_claude_live")
        currentClaudeBridgeError = nil

        defer {
            isBusy = false
            busyMessage = nil
        }

        do {
            try claudeStatuslineBridgeService.installBridge()
            refreshClaudeStatuslineBridgeState()
        } catch {
            currentClaudeBridgeError = error.localizedDescription
        }
    }

    func uninstallClaudeLiveLimitsBridge() async {
        guard !isBusy else { return }
        isBusy = true
        busyMessage = L10n.tr("busy.disconnecting_claude_bridge")
        currentClaudeBridgeError = nil

        defer {
            isBusy = false
            busyMessage = nil
        }

        do {
            try claudeStatuslineBridgeService.uninstallBridge()
            refreshClaudeStatuslineBridgeState()
        } catch {
            currentClaudeBridgeError = error.localizedDescription
        }
    }

    func refreshClaudeLiveLimitsBridge() async {
        guard !isBusy else { return }
        isBusy = true
        busyMessage = L10n.tr("busy.refreshing_claude_bridge")
        currentClaudeBridgeError = nil

        defer {
            isBusy = false
            busyMessage = nil
        }

        refreshClaudeStatuslineBridgeState()
    }

    func validateAll() async {
        for account in accounts {
            await validateAccount(account)
        }
        await refreshCurrentCLIState()
        await refreshCurrentCLIProbe(force: true)
        await refreshCurrentClaudeState()
    }

    func refreshCurrentValues(forceProbe: Bool = true) async {
        await refreshCurrentCLIPanel(forceProbe: forceProbe)
        await refreshCurrentClaudeState()
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
            Self.canAttemptExpiredResetRefresh(
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
        guard !isBusy else {
            return
        }

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
        guard !isBusy, !isRefreshingCurrentCLIProbe, !isRefreshingStoredCodexAccount else {
            return
        }

        guard let accountID = Self.nextStoredCodexAccountIDForAutoRefresh(
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
            let authData = try vault.read(account: account.keychainAccount)
            let result = try await codexAccountService.validate(authData: authData)
            try persistValidatedAccount(result, forAccountID: account.id)
        } catch {
            do {
                try updateAccount(account.id) { stored in
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
        await runBusy(L10n.tr("busy.deleting", account.label)) { [self] in
            try self.vault.delete(account: account.keychainAccount)
            self.accounts.removeAll { $0.id == account.id }
            try self.saveAccounts()
            await self.refreshCurrentCLIState()
            await self.refreshCurrentCLIProbe(force: true)
        }
    }

    func deleteClaudeAccount(_ account: ClaudeStoredAccount) async {
        await runBusy(L10n.tr("busy.deleting", account.label)) { [self] in
            try self.vault.delete(account: account.keychainAccount)
            self.claudeAccounts.removeAll { $0.id == account.id }
            try self.saveAccounts()
            await self.refreshCurrentClaudeState()
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

    func claudeAuthInstalled() -> Bool {
        claudeAuthStatusService.isInstalled()
    }

    func claudeLiveBridgeInstalled() -> Bool {
        currentClaudeLiveBridgeStatus.installed
    }

    func claudeLiveBridgeSnapshotUpdatedAt() -> Date? {
        currentClaudeLivePayload?.updatedAt
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
            guard let fingerprint = currentClaudeState.authFingerprint else { return nil }
            return claudeAccounts.first(where: { $0.authFingerprint == fingerprint })
        case .notInstalled, .loggedOut, .unreadable:
            return nil
        }
    }

    func currentCLIOverview() -> CurrentCLIOverview {
        let account = currentCLIReferenceAccount()
        let liveLimits = Self.liveCurrentCLIPanelSummary(probe: currentCLIProbe, probeError: currentCLIProbeError)
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

    func currentCLISummary() -> String {
        switch currentCLIState.source {
        case .missing:
            return L10n.tr("cli.summary.missing")
        case .stored:
            return L10n.tr("cli.summary.stored")
        case .external:
            return L10n.tr("cli.summary.external")
        case .unreadable:
            return L10n.tr("cli.summary.unreadable")
        }
    }

    func publishWidgetSnapshotNow() {
        publishWidgetSnapshotIfPossible()
    }

    func makeWidgetSnapshot(now: Date = .now) -> LimitsWidgetSnapshot {
        let codexOverview = currentCLIOverview()
        let codexLimits = Self.widgetLimitSnapshots(from: currentCLIDisplayRateLimitSections(now: now), now: now)
        let claudeOverview = currentClaudeOverview()
        let claudeLimits = Self.widgetLimitSnapshots(from: currentClaudeLiveRateLimitSections(), now: now)

        return LimitsWidgetSnapshot(
            generatedAt: now,
            providers: [
                LimitsWidgetProviderSnapshot(
                    id: .codex,
                    title: codexOverview.title,
                    subtitle: codexOverview.subtitle,
                    status: widgetCodexStatus(limits: codexLimits),
                    limits: codexLimits,
                    updatedAt: currentCLIValidatedAt(),
                    note: codexOverview.note ?? currentCLIProbeError
                ),
                LimitsWidgetProviderSnapshot(
                    id: .claude,
                    title: claudeOverview.title,
                    subtitle: claudeOverview.subtitle,
                    status: widgetClaudeStatus(limits: claudeLimits),
                    limits: claudeLimits,
                    updatedAt: claudeLiveBridgeSnapshotUpdatedAt() ?? claudeValidatedAt(),
                    note: claudeOverview.note ?? currentClaudeBridgeError ?? currentClaudeError
                ),
            ]
        )
    }

    nonisolated static func widgetLimitSnapshots(
        from sections: [RateLimitDisplaySection],
        now: Date = .now
    ) -> [LimitsWidgetLimitSnapshot] {
        sections.flatMap { section in
            section.rows.map { row in
                let resetIsStale = row.resetDate.map { $0 <= now } ?? false
                return LimitsWidgetLimitSnapshot(
                    id: "\(section.id).\(row.id)",
                    title: row.title,
                    remainingPercent: resetIsStale ? nil : row.remainingPercent,
                    resetDate: row.resetDate
                )
            }
        }
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

    private func publishWidgetSnapshotIfPossible(now: Date = .now) {
        do {
            try widgetSnapshotPublisher.publish(makeWidgetSnapshot(now: now))
            RuntimeLog.widget.debug("widget snapshot published")
        } catch {
            RuntimeLog.widget.warning("widget snapshot publish failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func currentCLIDetail() -> String {
        switch currentCLIState.source {
        case .missing:
            return L10n.tr("cli.detail.missing")
        case .stored(let id):
            if let label = accounts.first(where: { $0.id == id })?.label {
                return L10n.tr("cli.detail.stored.named", label)
            }
            return L10n.tr("cli.detail.stored.fallback")
        case .external(let accountId):
            if let accountId, let matched = accounts.first(where: { $0.accountId == accountId }) {
                return L10n.tr("cli.detail.external.matched", matched.label)
            }
            if let accountId {
                return L10n.tr("cli.detail.external.id", accountId)
            }
            return L10n.tr("cli.detail.external.unsaved")
        case .unreadable:
            return L10n.tr("cli.detail.unreadable")
        }
    }

    func currentCLIProbeWarningText() -> String? {
        currentCLIProbeError.map { Self.currentCLIProbeNote(for: $0) }
    }

    func hasExternalCLIAuthDrift() -> Bool {
        if case .external = currentCLIState.source {
            return true
        }
        return false
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
        let currentAuth = try globalAuthService.readGlobalAuth()
        let result = try await codexAccountService.validate(authData: currentAuth)
        try upsertAccount(from: result, preferredLabel: result.email)
    }

    private func currentCLIImportedAccount() -> StoredAccount? {
        Self.resolveImportedAccount(
            fingerprint: currentCLIState.authFingerprint,
            accountId: currentCLIState.accountId,
            email: currentCLIProbe?.email,
            accounts: accounts
        )
    }

    private func resolveCurrentClaudeAccount(status: ClaudeAuthStatus) -> ClaudeStoredAccount? {
        guard let identity = ClaudeAccountIdentity(email: status.email, organizationId: status.orgId) else {
            return nil
        }

        return claudeAccounts.first { $0.stableIdentity == identity }
            ?? claudeAccounts.first {
                $0.orgId == nil && $0.email.caseInsensitiveCompare(identity.normalizedEmail) == .orderedSame
            }
    }

    private func importCurrentClaudeAuthNow() throws {
        let credential = try globalClaudeCredentialService.readGlobalCredential()
        let status = try claudeAuthStatusService.readStatus()

        guard status.loggedIn, let email = status.email else {
            throw ClaudeAuthStatusServiceError.commandFailed(L10n.tr("claude.not_logged_in.error"))
        }

        try upsertClaudeAccount(
            credential: credential,
            status: status,
            preferredLabel: email
        )
    }

    private func upsertAccount(from result: AccountValidationResult, preferredLabel: String, existingID: UUID? = nil) throws {
        let existingIndex: Int? = {
            if let existingID {
                return accounts.firstIndex(where: { $0.id == existingID })
            }
            if let accountId = result.identity.accountId {
                return accounts.firstIndex(where: { $0.accountId == accountId })
            }
            return accounts.firstIndex(where: { $0.email.caseInsensitiveCompare(result.email) == .orderedSame })
        }()

        let keychainAccount: String
        let recordID: UUID
        let label: String
        let createdAt: Date

        if let existingIndex {
            keychainAccount = accounts[existingIndex].keychainAccount
            recordID = accounts[existingIndex].id
            label = accounts[existingIndex].label
            createdAt = accounts[existingIndex].createdAt
        } else {
            recordID = UUID()
            keychainAccount = "account.\(recordID.uuidString)"
            label = makeUniqueLabel(base: preferredLabel)
            createdAt = Date()
        }

        try vault.save(result.authData, account: keychainAccount, label: label)

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
            statusMessage: statusMessage(for: result.rateLimit),
            lastRateLimit: result.rateLimit,
            lastRateLimitsByLimitId: result.rateLimitsByLimitId,
            authFingerprint: result.authFingerprint,
            keychainAccount: keychainAccount
        )

        if let existingIndex {
            accounts[existingIndex] = updatedRecord
        } else {
            accounts.append(updatedRecord)
        }

        accounts.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        try saveAccounts()
    }

    private func updateAccount(_ id: UUID, mutate: (inout StoredAccount) -> Void) throws {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutate(&accounts[index])
        try saveAccounts()
    }

    private func persistValidatedCurrentCLIAccountIfKnown(_ result: AccountValidationResult) throws {
        guard let accountID = knownAccountID(for: result) else {
            return
        }

        try persistValidatedAccount(result, forAccountID: accountID)
    }

    private func persistValidatedAccount(_ result: AccountValidationResult, forAccountID id: UUID) throws {
        guard let account = accounts.first(where: { $0.id == id }) else {
            return
        }

        try vault.save(result.authData, account: account.keychainAccount, label: account.label)
        try updateAccount(id) { stored in
            stored.email = result.email
            stored.planType = result.planType
            stored.accountId = result.identity.accountId
            stored.authFingerprint = result.authFingerprint
            stored.lastValidatedAt = Date()
            stored.updatedAt = Date()
            stored.lastRateLimit = result.rateLimit
            stored.lastRateLimitsByLimitId = result.rateLimitsByLimitId
            stored.status = resolveStatus(from: result.rateLimit)
            stored.statusMessage = statusMessage(for: result.rateLimit)
        }
    }

    private func knownAccountID(for result: AccountValidationResult) -> UUID? {
        if case .stored(let id) = currentCLIState.source {
            return id
        }

        if let matched = Self.resolveImportedAccount(
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
    ) throws {
        let fingerprint = CodexAuthBlob.fingerprint(for: credential)
        let existingIndex: Int? = {
            if let existingID {
                return claudeAccounts.firstIndex(where: { $0.id == existingID })
            }
            return claudeAccounts.firstIndex(where: {
                $0.authFingerprint == fingerprint ||
                $0.email.caseInsensitiveCompare(status.email ?? preferredLabel) == .orderedSame
            })
        }()

        let keychainAccount: String
        let recordID: UUID
        let label: String
        let createdAt: Date

        if let existingIndex {
            keychainAccount = claudeAccounts[existingIndex].keychainAccount
            recordID = claudeAccounts[existingIndex].id
            label = claudeAccounts[existingIndex].label
            createdAt = claudeAccounts[existingIndex].createdAt
        } else {
            recordID = UUID()
            keychainAccount = "claude.\(recordID.uuidString)"
            label = makeUniqueClaudeLabel(base: preferredLabel)
            createdAt = Date()
        }

        try vault.save(credential, account: keychainAccount, label: label)

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
            keychainAccount: keychainAccount
        )

        if let existingIndex {
            claudeAccounts[existingIndex] = updatedRecord
        } else {
            claudeAccounts.append(updatedRecord)
        }

        claudeAccounts.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        try saveAccounts()
    }

    private func updateClaudeAccount(_ id: UUID, mutate: (inout ClaudeStoredAccount) -> Void) throws {
        guard let index = claudeAccounts.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutate(&claudeAccounts[index])
        try saveAccounts()
    }

    private func saveAccounts() throws {
        try persistence.save(
            PersistedState(
                accounts: accounts,
                claudeAccounts: claudeAccounts,
                retiredCredentials: retiredCredentials
            )
        )
    }

    private func purgeExpiredRetiredCredentials(now: Date = .now) throws {
        let expired = retiredCredentials.filter { $0.purgeAfter <= now }
        guard !expired.isEmpty else { return }

        var deleted = Set<UUID>()
        for credential in expired {
            do {
                try vault.delete(account: credential.keychainAccount)
                deleted.insert(credential.id)
            } catch {
                RuntimeLog.lifecycle.warning("retired credential cleanup deferred provider=\(credential.provider.rawValue, privacy: .public)")
            }
        }

        guard !deleted.isEmpty else { return }
        retiredCredentials.removeAll { deleted.contains($0.id) }
        try saveAccounts()
    }

    static func resolveStoredAccountMatch(identity: AuthIdentity, fingerprint: String, accounts: [StoredAccount]) -> StoredAccount? {
        if let exact = accounts.first(where: { $0.authFingerprint == fingerprint }) {
            return exact
        }

        guard let stableIdentity = CodexAccountIdentity(identity.accountId) else {
            return nil
        }
        let stableMatches = accounts.filter { $0.stableIdentity == stableIdentity }
        return stableMatches.count == 1 ? stableMatches[0] : nil
    }

    static func resolveImportedAccount(
        fingerprint: String?,
        accountId: String?,
        email: String?,
        accounts: [StoredAccount]
    ) -> StoredAccount? {
        if let fingerprint,
           let matched = accounts.first(where: { $0.authFingerprint == fingerprint }) {
            return matched
        }

        if let accountId,
           let matched = accounts.first(where: { $0.accountId == accountId }) {
            return matched
        }

        if let email,
           let matched = accounts.first(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame }) {
            return matched
        }

        return nil
    }

    private func runBusy(_ message: String, operation: @escaping () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        busyMessage = message
        errorMessage = nil

        defer {
            isBusy = false
            busyMessage = nil
        }

        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
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
        Self.validationStatus(forErrorMessage: error.localizedDescription)
    }

    nonisolated static func validationStatus(forErrorMessage message: String) -> AccountStatus {
        let message = message.lowercased()
        if message.contains("unauthorized") || message.contains("401") || message.contains("auth") || message.contains("login") {
            return .needsReauth
        }
        if message.contains("token_expired") || message.contains("token_invalidated") || message.contains("refresh token") || message.contains("signing in again") {
            return .needsReauth
        }
        return .validationFailed
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

    func currentCLIRateLimitSections() -> [RateLimitDisplaySection] {
        Self.liveCurrentCLIRateLimitSections(probe: currentCLIProbe, probeError: currentCLIProbeError)
    }

    func currentCLIDisplayRateLimitSections(now: Date = .now) -> [RateLimitDisplaySection] {
        let liveSections = currentCLIRateLimitSections()
        if !liveSections.isEmpty {
            return liveSections
        }

        guard let account = currentCLIReferenceAccount() else {
            return []
        }

        return Self.storedRateLimitSections(
            primary: account.lastRateLimit,
            byLimitId: account.lastRateLimitsByLimitId,
            now: now
        )
    }

    static func liveCurrentCLIPanelSummary(probe: CurrentCLIProbe?, probeError: String? = nil) -> String? {
        guard probeError == nil else { return nil }
        return probe?.rateLimit?.panelSummary()
    }

    static func liveCurrentCLIRateLimitSections(probe: CurrentCLIProbe?, probeError: String? = nil) -> [RateLimitDisplaySection] {
        guard probeError == nil else { return [] }
        return RateLimitDisplayBuilder.makeSections(
            primary: probe?.rateLimit,
            byLimitId: probe?.rateLimitsByLimitId
        )
    }

    func currentClaudeLiveRateLimitSections() -> [RateLimitDisplaySection] {
        guard let payload = currentClaudeLivePayload else {
            return []
        }

        var rows: [RateLimitDisplayRow] = []
        if let fiveHour = payload.snapshot.rateLimits?.fiveHour {
            let resetDate = resetDate(for: fiveHour.resetsAt)
            rows.append(
                RateLimitDisplayRow(
                    id: "claude.five_hour",
                    title: L10n.tr("limit.five_hour"),
                    usedPercent: normalizeUsedPercent(fiveHour.usedPercentage),
                    resetText: resetDate.map { RateLimitResetFormatter.expandedText(for: $0) },
                    resetDate: resetDate
                )
            )
        }

        if let sevenDay = payload.snapshot.rateLimits?.sevenDay {
            let resetDate = resetDate(for: sevenDay.resetsAt)
            rows.append(
                RateLimitDisplayRow(
                    id: "claude.seven_day",
                    title: L10n.tr("limit.weekly"),
                    usedPercent: normalizeUsedPercent(sevenDay.usedPercentage),
                    resetText: resetDate.map { RateLimitResetFormatter.expandedText(for: $0) },
                    resetDate: resetDate
                )
            )
        }

        guard !rows.isEmpty else {
            return []
        }

        return [
            RateLimitDisplaySection(
                id: "claude.live",
                title: "Claude Code",
                rows: rows
            )
        ]
    }

    func rateLimitSections(for account: StoredAccount) -> [RateLimitDisplaySection] {
        let useLiveProbe = isCurrentCLIAccount(account) && currentCLIProbe?.fingerprint == account.authFingerprint
        if useLiveProbe {
            return RateLimitDisplayBuilder.makeSections(
                primary: currentCLIProbe?.rateLimit,
                byLimitId: currentCLIProbe?.rateLimitsByLimitId
            )
        }

        return Self.storedRateLimitSections(
            primary: account.lastRateLimit,
            byLimitId: account.lastRateLimitsByLimitId
        )
    }

    func sortedCodexAccountsForSidebar(now: Date = .now) -> [StoredAccount] {
        let summaries = Dictionary(
            uniqueKeysWithValues: accounts.map { account in
                (account.id, sidebarLimitSummary(for: account, now: now))
            }
        )
        return Self.sortedCodexAccountsForSidebar(accounts, summaries: summaries)
    }

    nonisolated static func sortedCodexAccountsForSidebar(
        _ accounts: [StoredAccount],
        summaries: [UUID: SidebarLimitSummary?]
    ) -> [StoredAccount] {
        accounts.sorted { lhs, rhs in
            compareCodexSidebarAccounts(lhs, rhs, summaries: summaries)
        }
    }

    private nonisolated static func compareCodexSidebarAccounts(
        _ lhs: StoredAccount,
        _ rhs: StoredAccount,
        summaries: [UUID: SidebarLimitSummary?]
    ) -> Bool {
        let lhsSummary = summaries[lhs.id] ?? nil
        let rhsSummary = summaries[rhs.id] ?? nil
        let lhsHasData = lhsSummary?.hasLimitData == true
        let rhsHasData = rhsSummary?.hasLimitData == true

        if lhsHasData != rhsHasData {
            return lhsHasData
        }

        switch (lhsSummary?.nextResetDate, rhsSummary?.nextResetDate) {
        case let (lhsReset?, rhsReset?) where lhsReset != rhsReset:
            return lhsReset < rhsReset
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        let lhsScore = lhsSummary?.limitSortScore ?? -1
        let rhsScore = rhsSummary?.limitSortScore ?? -1
        if lhsScore != rhsScore {
            return lhsScore > rhsScore
        }

        let lhsStatusRank = sidebarStatusRank(lhs.status)
        let rhsStatusRank = sidebarStatusRank(rhs.status)
        if lhsStatusRank != rhsStatusRank {
            return lhsStatusRank < rhsStatusRank
        }

        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
    }

    private nonisolated static func sidebarStatusRank(_ status: AccountStatus) -> Int {
        switch status {
        case .ok:
            return 0
        case .limitReached:
            return 1
        case .unknown:
            return 2
        case .needsReauth:
            return 3
        case .validationFailed:
            return 4
        }
    }

    func currentCLISidebarLimitSummary(now: Date = .now) -> SidebarLimitSummary? {
        Self.sidebarLimitSummary(
            primary: currentCLIProbe?.rateLimit,
            byLimitId: currentCLIProbe?.rateLimitsByLimitId,
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
            return Self.sidebarLimitSummary(
                primary: currentCLIProbe?.rateLimit,
                byLimitId: currentCLIProbe?.rateLimitsByLimitId,
                now: now
            )
        }

        return Self.sidebarLimitSummary(
            primary: account.lastRateLimit,
            byLimitId: account.lastRateLimitsByLimitId,
            now: now
        )
    }

    nonisolated static func sidebarLimitSummary(
        primary: RateLimitSnapshotModel?,
        byLimitId: [String: RateLimitSnapshotModel]?,
        now: Date = .now
    ) -> SidebarLimitSummary? {
        guard let snapshot = byLimitId?["codex"] ?? primary else {
            return nil
        }

        let fiveHour = remainingWindow(from: snapshot, minutes: 300, now: now)
        let weekly = remainingWindow(from: snapshot, minutes: 10_080, now: now)

        guard fiveHour.remainingPercent != nil || weekly.remainingPercent != nil else {
            return nil
        }

        let nextResetDate = [fiveHour.resetDate, weekly.resetDate]
            .compactMap(\.self)
            .min()

        return SidebarLimitSummary(
            fiveHourRemainingPercent: fiveHour.remainingPercent,
            weeklyRemainingPercent: weekly.remainingPercent,
            nextResetDate: nextResetDate
        )
    }

    private nonisolated static func remainingWindow(
        from snapshot: RateLimitSnapshotModel,
        minutes: Int64,
        now: Date
    ) -> (remainingPercent: Int?, resetDate: Date?) {
        let window = [snapshot.primary, snapshot.secondary]
            .compactMap(\.self)
            .first { $0.windowDurationMins == minutes }

        guard let window else {
            return (nil, nil)
        }

        let resetDate = window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        if let resetDate, resetDate <= now {
            return (nil, nil)
        }

        return (max(0, 100 - window.usedPercent), resetDate)
    }

    nonisolated static func currentCLIProbeCanBeReused(
        _ probe: CurrentCLIProbe,
        expectedFingerprint: String,
        now: Date,
        ttl: TimeInterval
    ) -> Bool {
        guard probe.fingerprint == expectedFingerprint else {
            return false
        }

        guard now.timeIntervalSince(probe.validatedAt) < ttl else {
            return false
        }

        return !storedSnapshotIsStale(
            primary: probe.rateLimit,
            byLimitId: probe.rateLimitsByLimitId,
            now: now
        )
    }

    func currentCLIProbeHasExpiredReset(now: Date = .now) -> Bool {
        guard let probe = currentCLIProbe else {
            return false
        }

        return Self.currentCLIProbeHasExpiredReset(probe, now: now)
    }

    nonisolated static func currentCLIProbeHasExpiredReset(_ probe: CurrentCLIProbe, now: Date = .now) -> Bool {
        storedSnapshotIsStale(primary: probe.rateLimit, byLimitId: probe.rateLimitsByLimitId, now: now)
    }

    nonisolated static func canAttemptExpiredResetRefresh(
        lastAttempt: Date?,
        now: Date,
        retryInterval: TimeInterval
    ) -> Bool {
        guard let lastAttempt else {
            return true
        }
        return now.timeIntervalSince(lastAttempt) >= retryInterval
    }

    nonisolated static func nextStoredCodexAccountIDForAutoRefresh(
        accounts: [StoredAccount],
        currentAccountID: UUID?,
        lastAttempts: [UUID: Date],
        now: Date,
        retryInterval: TimeInterval
    ) -> UUID? {
        accounts
            .filter { account in
                guard account.id != currentAccountID else {
                    return false
                }
                guard account.status != .needsReauth else {
                    return false
                }
                guard storedCodexAccountNeedsAutoRefresh(account, now: now) else {
                    return false
                }
                if let lastAttempt = lastAttempts[account.id], now.timeIntervalSince(lastAttempt) < retryInterval {
                    return false
                }
                return true
            }
            .sorted { lhs, rhs in
                let lhsReset = staleCodexResetDate(for: lhs) ?? .distantFuture
                let rhsReset = staleCodexResetDate(for: rhs) ?? .distantFuture
                if lhsReset != rhsReset {
                    return lhsReset < rhsReset
                }

                let lhsValidated = lhs.lastValidatedAt ?? .distantPast
                let rhsValidated = rhs.lastValidatedAt ?? .distantPast
                if lhsValidated != rhsValidated {
                    return lhsValidated < rhsValidated
                }

                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
            .first?
            .id
    }

    nonisolated static func storedCodexAccountNeedsAutoRefresh(_ account: StoredAccount, now: Date = .now) -> Bool {
        let hasAnyLimitSnapshot = account.lastRateLimit != nil || account.lastRateLimitsByLimitId?.isEmpty == false
        if !hasAnyLimitSnapshot {
            return true
        }

        return storedSnapshotIsStale(
            primary: account.lastRateLimit,
            byLimitId: account.lastRateLimitsByLimitId,
            now: now
        )
    }

    private nonisolated static func staleCodexResetDate(for account: StoredAccount) -> Date? {
        let snapshot = account.lastRateLimitsByLimitId?["codex"] ?? account.lastRateLimit
        return snapshot?.fiveHourResetDate
    }

    nonisolated static func storedRateLimitSections(
        primary: RateLimitSnapshotModel?,
        byLimitId: [String: RateLimitSnapshotModel]?,
        now: Date = .now
    ) -> [RateLimitDisplaySection] {
        let hasExactLimitSnapshots = byLimitId?.isEmpty == false
        return RateLimitDisplayBuilder.makeSections(
            primary: hasExactLimitSnapshots ? nil : primary,
            byLimitId: byLimitId,
            excludingExpiredRowsAt: now
        )
    }

    nonisolated static func storedRateLimitSummary(
        primary: RateLimitSnapshotModel?,
        byLimitId: [String: RateLimitSnapshotModel]?,
        now: Date = .now
    ) -> String? {
        if storedSnapshotIsStale(primary: primary, byLimitId: byLimitId, now: now) {
            return L10n.tr("reset.stale.expanded")
        }

        return primary?.compactUsageSummary()
    }

    nonisolated static func storedRemainingPercent(
        primary: RateLimitSnapshotModel?,
        byLimitId: [String: RateLimitSnapshotModel]?,
        now: Date = .now
    ) -> Int? {
        sidebarLimitSummary(primary: primary, byLimitId: byLimitId, now: now)?.fiveHourRemainingPercent
    }

    private nonisolated static func storedSnapshotIsStale(
        primary: RateLimitSnapshotModel?,
        byLimitId: [String: RateLimitSnapshotModel]?,
        now: Date
    ) -> Bool {
        if let codex = byLimitId?["codex"], codex.fiveHourHasReset(now: now) {
            return true
        }

        if let primary, primary.fiveHourHasReset(now: now) {
            return true
        }

        return false
    }

    func storedRateLimitSummary(for account: StoredAccount) -> String? {
        Self.storedRateLimitSummary(
            primary: account.lastRateLimit,
            byLimitId: account.lastRateLimitsByLimitId
        )
    }

    func remainingPercent(for account: StoredAccount) -> Int? {
        sidebarLimitSummary(for: account)?.fiveHourRemainingPercent
    }

    func sidebarSecondaryText(for account: StoredAccount) -> String {
        storedRateLimitSummary(for: account) ?? account.email
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
            return Self.currentCLIProbeNote(for: probeError)
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
            return Self.currentCLIProbeNote(for: probeError)
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

    nonisolated static func currentCLIProbeNote(for message: String) -> String {
        let lowered = message.lowercased()
        if lowered.contains("unauthorized") || lowered.contains("401") || lowered.contains("auth") || lowered.contains("login") {
            return L10n.tr("cli.current_reauth_needed")
        }
        return L10n.tr("cli.live_update_failed")
    }

    private func refreshClaudeStatuslineBridgeState() {
        do {
            currentClaudeLiveBridgeStatus = try claudeStatuslineBridgeService.bridgeStatus()
            currentClaudeBridgeError = nil
        } catch {
            currentClaudeLiveBridgeStatus = ClaudeStatuslineBridgeStatus(installed: false, hasSnapshot: false, preservingOriginalStatusLine: false)
            currentClaudeLivePayload = nil
            currentClaudeBridgeError = error.localizedDescription
            return
        }

        guard currentClaudeLiveBridgeStatus.hasSnapshot else {
            currentClaudeLivePayload = nil
            return
        }

        do {
            currentClaudeLivePayload = try claudeStatuslineBridgeService.readSnapshot()
            currentClaudeBridgeError = nil
        } catch {
            currentClaudeLivePayload = nil
            currentClaudeBridgeError = error.localizedDescription
        }
    }

    private func normalizeUsedPercent(_ value: Double?) -> Int {
        let raw = Int((value ?? 0).rounded())
        return min(max(raw, 0), 100)
    }

    private func resetDate(for timestamp: Int64?) -> Date? {
        guard let timestamp else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    private func refreshStoredClaudeMetadataIfNeeded() throws {
        guard
            let status = currentClaudeStatus ?? (try? claudeAuthStatusService.readStatus()),
            status.loggedIn,
            let email = status.email,
            let fingerprint = currentClaudeState.authFingerprint ?? (try? globalClaudeCredentialService.readGlobalCredential()).map({ CodexAuthBlob.fingerprint(for: $0) })
        else {
            return
        }

        if let current = currentClaudeReferenceAccount() {
            try updateClaudeAccount(current.id) { stored in
                stored.email = email
                stored.subscriptionType = status.subscriptionType ?? stored.subscriptionType
                stored.authMethod = status.authMethod
                stored.orgId = status.orgId
                stored.orgName = status.orgName
                stored.authFingerprint = fingerprint
                stored.updatedAt = Date()
                stored.lastValidatedAt = Date()
                stored.status = .ok
                stored.statusMessage = L10n.tr("claude.account.ready")
            }
        }
    }
}
