import AppKit
import Foundation

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

    private let persistence = AccountsPersistence()
    private let vault = KeychainAuthVault()
    private let globalAuthService = GlobalCodexAuthService()
    private let codexAccountService = CodexAccountService()
    private let globalClaudeCredentialService = GlobalClaudeCredentialService()
    private let claudeAuthStatusService = ClaudeAuthStatusService()
    private let claudeStatuslineBridgeService = ClaudeStatuslineBridgeService()
    private let currentCLIProbeTTL: TimeInterval = 300
    private let backgroundRefreshInterval: TimeInterval = 300
    private var backgroundRefreshTask: Task<Void, Never>?

    init() {
        Task { await bootstrap() }
        startBackgroundRefreshLoop()
    }

    func bootstrap() async {
        do {
            let state = try persistence.load()
            accounts = state.accounts.sorted(by: { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending })
            claudeAccounts = state.claudeAccounts.sorted(by: { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending })
            await refreshCurrentCLIState()
            await refreshCurrentClaudeState()
            await adoptCurrentClaudeAccountIfNeeded()

            if accounts.isEmpty, globalAuthService.hasGlobalAuth() {
                try await importCurrentCLIAuthNow()
            }
            await validateAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshCurrentCLIState() async {
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

        if !force, let probe = currentCLIProbe, probe.fingerprint == fingerprint, Date().timeIntervalSince(probe.validatedAt) < currentCLIProbeTTL {
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
                fingerprint: fingerprint,
                email: result.email,
                planType: result.planType,
                rateLimit: result.rateLimit,
                rateLimitsByLimitId: result.rateLimitsByLimitId,
                validatedAt: Date()
            )
            currentCLIProbeError = nil
        } catch {
            currentCLIProbeError = error.localizedDescription
        }
    }

    func refreshCurrentCLIPanel(forceProbe: Bool = false) async {
        await refreshCurrentCLIState()
        await refreshCurrentCLIProbe(force: forceProbe)
    }

    func refreshCurrentClaudeState() async {
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

            let credential = try globalClaudeCredentialService.readGlobalCredential()
            let fingerprint = CodexAuthBlob.fingerprint(for: credential)
            if let matched = claudeAccounts.first(where: { $0.authFingerprint == fingerprint }) {
                currentClaudeState = CurrentClaudeState(source: .stored(matched.id), authFingerprint: fingerprint)
            } else {
                currentClaudeState = CurrentClaudeState(source: .external(status.email), authFingerprint: fingerprint)
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
        await runBusy("Выполняю вход…") { [self] in
            let result = try await self.codexAccountService.loginNewAccount { url in
                NSWorkspace.shared.open(url)
            }
            try self.upsertAccount(from: result, preferredLabel: result.email)
            await self.refreshCurrentCLIState()
            await self.validateAll()
        }
    }

    func importCurrentCLIAuth() async {
        await runBusy("Импортирую текущую CLI-авторизацию…") { [self] in
            try await self.importCurrentCLIAuthNow()
            await self.refreshCurrentCLIState()
            await self.validateAll()
        }
    }

    func importCurrentClaudeAuth() async {
        await runBusy("Импортирую текущий Claude Code…") { [self] in
            try self.importCurrentClaudeAuthNow()
            await self.refreshCurrentClaudeState()
        }
    }

    func activateAccount(_ account: StoredAccount) async {
        await runBusy("Переключаю глобальную авторизацию…") { [self] in
            let authData = try self.vault.read(account: account.keychainAccount)
            try self.globalAuthService.writeGlobalAuth(authData)
            await self.refreshCurrentCLIState()
            await self.refreshCurrentCLIProbe(force: true)
        }
    }

    func reauthenticateAccount(_ account: StoredAccount) async {
        await runBusy("Повторно авторизую \(account.label)…") { [self] in
            let result = try await self.codexAccountService.loginNewAccount { url in
                NSWorkspace.shared.open(url)
            }
            try self.upsertAccount(from: result, preferredLabel: account.label, existingID: account.id)
            await self.refreshCurrentCLIState()
            await self.validateAll()
        }
    }

    func activateClaudeAccount(_ account: ClaudeStoredAccount) async {
        await runBusy("Переключаю Claude Code…") { [self] in
            let credential = try self.vault.read(account: account.keychainAccount)
            try self.globalClaudeCredentialService.writeGlobalCredential(credential)
            await self.refreshCurrentClaudeState()
            try self.refreshStoredClaudeMetadataIfNeeded()
        }
    }

    func refreshCurrentClaudeAccount() async {
        await runBusy("Обновляю Claude Code…") { [self] in
            try self.refreshStoredClaudeMetadataIfNeeded()
            await self.refreshCurrentClaudeState()
        }
    }

    func installClaudeLiveLimitsBridge() async {
        guard !isBusy else { return }
        isBusy = true
        busyMessage = "Подключаю живые лимиты Claude…"
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
        busyMessage = "Отключаю мост Claude…"
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
        busyMessage = "Обновляю мост Claude…"
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

        await refreshCurrentCLIPanel(forceProbe: false)
        await refreshCurrentClaudeState()
    }

    func validateAccount(_ account: StoredAccount) async {
        do {
            let authData = try vault.read(account: account.keychainAccount)
            let result = try await codexAccountService.validate(authData: authData)
            try updateAccount(account.id) { stored in
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
        } catch {
            do {
                try updateAccount(account.id) { stored in
                    stored.lastValidatedAt = Date()
                    stored.updatedAt = Date()
                    stored.status = classifyValidationError(error)
                    stored.statusMessage = error.localizedDescription
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
        await runBusy("Удаляю \(account.label)…") { [self] in
            try self.vault.delete(account: account.keychainAccount)
            self.accounts.removeAll { $0.id == account.id }
            try self.saveAccounts()
            await self.refreshCurrentCLIState()
            await self.refreshCurrentCLIProbe(force: true)
        }
    }

    func deleteClaudeAccount(_ account: ClaudeStoredAccount) async {
        await runBusy("Удаляю \(account.label)…") { [self] in
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
        let liveLimits = currentCLIProbe?.rateLimit?.panelSummary()
        let fallbackLimits = account?.lastRateLimit?.panelSummary()
        let probeBackedSubtitle = subtitle(for: account, probe: currentCLIProbe)

        switch currentCLIState.source {
        case .stored:
            return CurrentCLIOverview(
                title: titleForStoredAccount(account, probe: currentCLIProbe),
                subtitle: probeBackedSubtitle,
                limits: liveLimits ?? fallbackLimits,
                note: noteForStoredAccount(account)
            )
        case .external:
            return CurrentCLIOverview(
                title: titleForExternalAuth(account, probe: currentCLIProbe),
                subtitle: probeBackedSubtitle,
                limits: liveLimits ?? fallbackLimits,
                note: noteForExternalAuth(account)
            )
        case .missing:
            return CurrentCLIOverview(
                title: "Нет CLI-авторизации",
                subtitle: nil,
                limits: nil,
                note: accounts.isEmpty ? "Добавьте первый аккаунт." : "Выберите сохранённый снимок или добавьте новый аккаунт."
            )
        case .unreadable:
            return CurrentCLIOverview(
                title: "Не удалось прочитать auth.json",
                subtitle: nil,
                limits: nil,
                note: accounts.isEmpty ? "Исправьте ~/.codex/auth.json или добавьте новый аккаунт." : "Исправьте auth.json или переключитесь на сохранённый снимок."
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
                note: account == nil ? "Импортируйте текущий Claude Code, чтобы сохранить снимок и быстро переключаться между аккаунтами." : claudeNote(account: account)
            )
        case .loggedOut:
            return CurrentClaudeOverview(
                title: "Claude Code не авторизован",
                subtitle: nil,
                note: "Войдите в Claude Code в терминале, затем импортируйте текущий аккаунт сюда."
            )
        case .notInstalled:
            return CurrentClaudeOverview(
                title: "Claude Code не установлен",
                subtitle: nil,
                note: "Установите CLI `claude`, чтобы приложение могло увидеть текущий аккаунт."
            )
        case .unreadable:
            return CurrentClaudeOverview(
                title: "Не удалось прочитать Claude Code",
                subtitle: nil,
                note: currentClaudeError ?? "Приложение не смогло получить текущую авторизацию Claude Code."
            )
        }
    }

    func shouldOfferAddAccountAsPrimaryAction() -> Bool {
        accounts.isEmpty && (isCurrentCLIAuthMissing() || isCurrentCLIAuthUnreadable())
    }

    func currentCLISummary() -> String {
        switch currentCLIState.source {
        case .missing:
            return "CLI-авторизация отсутствует"
        case .stored:
            return "Активен сохранённый аккаунт"
        case .external:
            return "Активна текущая CLI-авторизация"
        case .unreadable:
            return "Не удалось прочитать CLI-авторизацию"
        }
    }

    func currentCLIDetail() -> String {
        switch currentCLIState.source {
        case .missing:
            return "Глобальный ~/.codex/auth.json отсутствует."
        case .stored(let id):
            if let label = accounts.first(where: { $0.id == id })?.label {
                return "\(label) активен для следующих CLI-команд."
            }
            return "Сохранённый аккаунт активен для следующих CLI-команд."
        case .external(let accountId):
            if let accountId, let matched = accounts.first(where: { $0.accountId == accountId }) {
                return "Сейчас активна CLI-авторизация для \(matched.label). Аккаунт уже сохранён в приложении."
            }
            if let accountId {
                return "Сейчас активна CLI-авторизация \(accountId). Импортируйте её, чтобы использовать в приложении."
            }
            return "Сейчас активна CLI-авторизация, которая ещё не сохранена в приложении."
        case .unreadable:
            return "Глобальный ~/.codex/auth.json существует, но приложение не смогло прочитать его как корректный auth blob."
        }
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

    private func adoptCurrentClaudeAccountIfNeeded() async {
        guard claudeAccounts.isEmpty else {
            return
        }

        guard case .external = currentClaudeState.source else {
            return
        }

        do {
            try importCurrentClaudeAuthNow()
            await refreshCurrentClaudeState()
        } catch {
            currentClaudeError = error.localizedDescription
        }
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

    private func importCurrentClaudeAuthNow() throws {
        let credential = try globalClaudeCredentialService.readGlobalCredential()
        let status = try claudeAuthStatusService.readStatus()

        guard status.loggedIn, let email = status.email else {
            throw ClaudeAuthStatusServiceError.commandFailed("Claude Code сейчас не авторизован.")
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
            orgName: status.orgName,
            createdAt: createdAt,
            updatedAt: Date(),
            lastValidatedAt: Date(),
            status: .ok,
            statusMessage: "Аккаунт Claude Code готов.",
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
        try persistence.save(PersistedState(accounts: accounts, claudeAccounts: claudeAccounts))
    }

    static func resolveStoredAccountMatch(identity: AuthIdentity, fingerprint: String, accounts: [StoredAccount]) -> StoredAccount? {
        accounts.first(where: { matches(identity: identity, fingerprint: fingerprint, account: $0) })
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
            return "За 5 часов использовано \(primary.usedPercent)%"
        }

        return nil
    }

    private func classifyValidationError(_ error: Error) -> AccountStatus {
        let message = error.localizedDescription.lowercased()
        if message.contains("unauthorized") || message.contains("401") || message.contains("auth") || message.contains("login") {
            return .needsReauth
        }
        return .validationFailed
    }

    private static func matches(identity: AuthIdentity, fingerprint: String, account: StoredAccount) -> Bool {
        if let accountId = identity.accountId, let storedAccountId = account.accountId {
            guard accountId == storedAccountId else {
                return false
            }
            return fingerprint == account.authFingerprint
        }
        return fingerprint == account.authFingerprint
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
        RateLimitDisplayBuilder.makeSections(
            primary: currentCLIProbe?.rateLimit ?? currentCLIReferenceAccount()?.lastRateLimit,
            byLimitId: currentCLIProbe?.rateLimitsByLimitId ?? currentCLIReferenceAccount()?.lastRateLimitsByLimitId
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
                    title: "5ч лимит",
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
                    title: "Недельный лимит",
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
        return RateLimitDisplayBuilder.makeSections(
            primary: useLiveProbe ? currentCLIProbe?.rateLimit : account.lastRateLimit,
            byLimitId: useLiveProbe ? currentCLIProbe?.rateLimitsByLimitId : account.lastRateLimitsByLimitId
        )
    }

    func sidebarSecondaryText(for account: StoredAccount) -> String {
        account.lastRateLimit?.compactUsageSummary() ?? account.email
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
            return "План Pro"
        case "plus":
            return "План Plus"
        case "free":
            return "Бесплатный план"
        case "unknown":
            return "План неизвестен"
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
            return "Подписка Claude"
        case "unknown", nil:
            return "План неизвестен"
        default:
            return value ?? "План неизвестен"
        }
    }

    private func titleForStoredAccount(_ account: StoredAccount?, probe: CurrentCLIProbe?) -> String {
        if let account {
            return account.label
        }
        return probe?.email ?? "Сохранённый аккаунт"
    }

    private func titleForExternalAuth(_ account: StoredAccount?, probe: CurrentCLIProbe?) -> String {
        if let probe {
            return probe.email
        }
        if let account {
            return account.label
        }
        return currentCLIState.accountId ?? "Внешняя авторизация"
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
                return "Этому аккаунту Claude Code нужен повторный вход в терминале."
            }
            if let orgName = account.orgName, !orgName.isEmpty {
                return "Организация: \(orgName). Лимиты Claude я пока намеренно не рисую, потому что у Anthropic они живут внутри живой сессии и здесь нельзя честно обещать точность."
            }
        }

        return "Лимиты Claude я пока намеренно не рисую, потому что у Anthropic они живут внутри живой сессии и здесь нельзя честно обещать точность."
    }

    private func noteForStoredAccount(_ account: StoredAccount?) -> String? {
        if let probeError = currentCLIProbeError {
            return currentCLIProbeNote(for: probeError)
        }
        guard let account else {
            return currentCLIProbe == nil && isRefreshingCurrentCLIProbe ? "Обновляю живые лимиты…" : nil
        }
        if account.lastRateLimit == nil {
            return currentCLIProbe == nil && isRefreshingCurrentCLIProbe ? "Обновляю живые лимиты…" : "Нажмите «Обновить», чтобы загрузить лимиты."
        }
        if account.status == .limitReached {
            return account.statusMessage ?? "Лимит достигнут."
        }
        if account.status == .needsReauth {
            return "Нужна повторная авторизация."
        }
        if account.status == .validationFailed {
            return "Последняя проверка завершилась ошибкой."
        }
        return nil
    }

    private func noteForExternalAuth(_ account: StoredAccount?) -> String? {
        if let probeError = currentCLIProbeError {
            return currentCLIProbeNote(for: probeError)
        }
        if isRefreshingCurrentCLIProbe && currentCLIProbe == nil {
            return "Обновляю живые лимиты…"
        }
        if account != nil {
            return nil
        }
        return "Импортируйте текущую авторизацию, чтобы она появилась в приложении."
    }

    private func currentCLIProbeNote(for message: String) -> String {
        let lowered = message.lowercased()
        if lowered.contains("unauthorized") || lowered.contains("401") || lowered.contains("auth") || lowered.contains("login") {
            return "Текущей авторизации нужен повторный вход."
        }
        return "Не удалось обновить живые лимиты."
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
                stored.orgName = status.orgName
                stored.authFingerprint = fingerprint
                stored.updatedAt = Date()
                stored.lastValidatedAt = Date()
                stored.status = .ok
                stored.statusMessage = "Аккаунт Claude Code готов."
            }
        }
    }
}
