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

    @Published private(set) var accounts: [StoredAccount] = []
    @Published private(set) var currentCLIState = CurrentCLIState()
    @Published var isBusy = false
    @Published var busyMessage: String?
    @Published var errorMessage: String?

    private let persistence = AccountsPersistence()
    private let vault = KeychainAuthVault()
    private let globalAuthService = GlobalCodexAuthService()
    private let codexAccountService = CodexAccountService()

    init() {
        Task { await bootstrap() }
    }

    func bootstrap() async {
        do {
            accounts = try persistence.load().accounts.sorted(by: { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending })
            await refreshCurrentCLIState()

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
            errorMessage = error.localizedDescription
        }
    }

    func addAccount() async {
        await runBusy("Signing in…") { [self] in
            let result = try await self.codexAccountService.loginNewAccount { url in
                NSWorkspace.shared.open(url)
            }
            try self.upsertAccount(from: result, preferredLabel: result.email)
            await self.refreshCurrentCLIState()
            await self.validateAll()
        }
    }

    func importCurrentCLIAuth() async {
        await runBusy("Importing current CLI auth…") { [self] in
            try await self.importCurrentCLIAuthNow()
            await self.refreshCurrentCLIState()
            await self.validateAll()
        }
    }

    func activateAccount(_ account: StoredAccount) async {
        await runBusy("Switching global auth…") { [self] in
            let authData = try self.vault.read(account: account.keychainAccount)
            try self.globalAuthService.writeGlobalAuth(authData)
            await self.refreshCurrentCLIState()
        }
    }

    func reauthenticateAccount(_ account: StoredAccount) async {
        await runBusy("Re-authenticating \(account.label)…") { [self] in
            let result = try await self.codexAccountService.loginNewAccount { url in
                NSWorkspace.shared.open(url)
            }
            try self.upsertAccount(from: result, preferredLabel: account.label, existingID: account.id)
            await self.refreshCurrentCLIState()
            await self.validateAll()
        }
    }

    func validateAll() async {
        for account in accounts {
            await validateAccount(account)
        }
        await refreshCurrentCLIState()
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
    }

    func deleteAccount(_ account: StoredAccount) async {
        await runBusy("Deleting \(account.label)…") { [self] in
            try self.vault.delete(account: account.keychainAccount)
            self.accounts.removeAll { $0.id == account.id }
            try self.saveAccounts()
            await self.refreshCurrentCLIState()
        }
    }

    func isCurrentCLIAccount(_ account: StoredAccount) -> Bool {
        if case .stored(let id) = currentCLIState.source {
            return id == account.id
        }
        return false
    }

    func menuPanelAccounts() -> [StoredAccount] {
        if case .stored(let id) = currentCLIState.source {
            return accounts.filter { $0.id != id }
        }
        return accounts
    }

    func currentCLIReferenceAccount() -> StoredAccount? {
        switch currentCLIState.source {
        case .stored(let id):
            return accounts.first(where: { $0.id == id })
        case .external(let accountId):
            guard let accountId else { return nil }
            return accounts.first(where: { $0.accountId == accountId })
        case .missing, .unreadable:
            return nil
        }
    }

    func currentCLIOverview() -> CurrentCLIOverview {
        let account = currentCLIReferenceAccount()

        switch currentCLIState.source {
        case .stored:
            return CurrentCLIOverview(
                title: account?.label ?? "Stored account",
                subtitle: subtitle(for: account),
                limits: account?.lastRateLimit?.panelSummary(),
                note: noteForStoredAccount(account)
            )
        case .external:
            return CurrentCLIOverview(
                title: account?.label ?? (currentCLIState.accountId ?? "External auth"),
                subtitle: subtitle(for: account),
                limits: account?.lastRateLimit?.panelSummary(),
                note: noteForExternalAuth(account)
            )
        case .missing:
            return CurrentCLIOverview(
                title: "No CLI auth",
                subtitle: nil,
                limits: nil,
                note: accounts.isEmpty ? "Add your first account." : "Pick a saved snapshot or add a new one."
            )
        case .unreadable:
            return CurrentCLIOverview(
                title: "Unreadable auth file",
                subtitle: nil,
                limits: nil,
                note: accounts.isEmpty ? "Fix ~/.codex/auth.json or add a new account." : "Fix auth.json or switch to a saved snapshot."
            )
        }
    }

    func shouldOfferAddAccountAsPrimaryAction() -> Bool {
        accounts.isEmpty && (isCurrentCLIAuthMissing() || isCurrentCLIAuthUnreadable())
    }

    func currentCLISummary() -> String {
        switch currentCLIState.source {
        case .missing:
            return "CLI auth missing"
        case .stored:
            return "Stored account active"
        case .external(let accountId):
            if let accountId {
                return "CLI auth drifted (\(accountId))"
            }
            return "CLI auth drifted"
        case .unreadable:
            return "CLI auth unreadable"
        }
    }

    func currentCLIDetail() -> String {
        switch currentCLIState.source {
        case .missing:
            return "Global ~/.codex/auth.json is missing."
        case .stored(let id):
            if let label = accounts.first(where: { $0.id == id })?.label {
                return "\(label) is active for future CLI commands."
            }
            return "A saved account is active for future CLI commands."
        case .external(let accountId):
            if let accountId, let matched = accounts.first(where: { $0.accountId == accountId }) {
                return "Global ~/.codex/auth.json points to \(matched.label), but the saved auth snapshot differs."
            }
            if let accountId {
                return "Global ~/.codex/auth.json points to \(accountId). Import it here or switch to a saved account."
            }
            return "Global ~/.codex/auth.json does not match any saved account."
        case .unreadable:
            return "Global ~/.codex/auth.json exists, but this app could not read it as a valid auth blob."
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
        if case .external = currentCLIState.source {
            return true
        }
        return false
    }

    private func importCurrentCLIAuthNow() async throws {
        let currentAuth = try globalAuthService.readGlobalAuth()
        let result = try await codexAccountService.validate(authData: currentAuth)
        try upsertAccount(from: result, preferredLabel: result.email)
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

    private func saveAccounts() throws {
        try persistence.save(PersistedState(accounts: accounts))
    }

    static func resolveStoredAccountMatch(identity: AuthIdentity, fingerprint: String, accounts: [StoredAccount]) -> StoredAccount? {
        accounts.first(where: { matches(identity: identity, fingerprint: fingerprint, account: $0) })
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
            return "Primary window \(primary.usedPercent)% used"
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

    private func subtitle(for account: StoredAccount?) -> String? {
        guard let account else { return nil }
        if account.label.caseInsensitiveCompare(account.email) != .orderedSame {
            return account.email
        }
        if account.planType.caseInsensitiveCompare("unknown") != .orderedSame {
            return account.planType.capitalized
        }
        return nil
    }

    private func noteForStoredAccount(_ account: StoredAccount?) -> String? {
        guard let account else {
            return nil
        }
        if account.lastRateLimit == nil {
            return "Validate to load limits."
        }
        if account.status == .limitReached {
            return account.statusMessage ?? "Limit reached."
        }
        if account.status == .needsReauth {
            return "Re-authentication needed."
        }
        if account.status == .validationFailed {
            return "Last validation failed."
        }
        return nil
    }

    private func noteForExternalAuth(_ account: StoredAccount?) -> String {
        if account != nil {
            return "Saved snapshot differs."
        }
        return "Import current auth or switch to a saved snapshot."
    }
}
