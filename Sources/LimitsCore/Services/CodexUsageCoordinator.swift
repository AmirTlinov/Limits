import Foundation
import LimitsShared

public struct CodexUsageCoordinatorSnapshot: Sendable {
    public let accounts: AccountsRepositorySnapshot
    public let usage: CodexUsageRepositorySnapshot
    public let rateCard: OpenAIRateCardRevision
    public let priceChange: OpenAIPriceChange?
    public let currentValidation: AccountValidationResult?
    public let importReport: CodexRolloutImportReport?

    public init(
        accounts: AccountsRepositorySnapshot,
        usage: CodexUsageRepositorySnapshot,
        rateCard: OpenAIRateCardRevision,
        priceChange: OpenAIPriceChange?,
        currentValidation: AccountValidationResult?,
        importReport: CodexRolloutImportReport?
    ) {
        self.accounts = accounts
        self.usage = usage
        self.rateCard = rateCard
        self.priceChange = priceChange
        self.currentValidation = currentValidation
        self.importReport = importReport
    }
}

public actor CodexUsageCoordinator {
    public static let selectedLimitsTTL: TimeInterval = 15 * 60
    public static let selectedUsageTTL: TimeInterval = 60 * 60
    public static let backgroundLimitsTTL: TimeInterval = 60 * 60
    public static let backgroundUsageTTL: TimeInterval = 6 * 60 * 60
    public static let initialBackoff: TimeInterval = 5 * 60
    public static let maximumBackoff: TimeInterval = 60 * 60

    private struct EndpointKey: Hashable, Sendable {
        let accountID: String
        let endpoint: CodexUsageEndpointKind
    }

    private struct RefreshIntent: Sendable {
        let currentAccountLocalID: UUID?
        let selectedAccountLocalID: UUID?
        let forceAccountIDs: Set<UUID>
        let now: Date

        func covers(_ other: RefreshIntent) -> Bool {
            currentAccountLocalID == other.currentAccountLocalID
                && selectedAccountLocalID == other.selectedAccountLocalID
                && forceAccountIDs.isSuperset(of: other.forceAccountIDs)
        }
    }

    private struct RefreshOperation: Sendable {
        let id: UUID
        let intent: RefreshIntent
        let task: Task<CodexUsageCoordinatorSnapshot, Error>
    }

    private let accountsRepository: AccountsRepository
    private let usageRepository: CodexUsageRepository
    private let sessionCoordinator: CodexSessionCoordinator
    private let importer: CodexRolloutUsageImporter?
    private let pricingCatalog: OpenAIPricingCatalog
    private let codexHome: URL?
    private let allowsServerProbes: Bool
    private var refreshOperation: RefreshOperation?
    private var failureCounts: [EndpointKey: Int] = [:]
    private var watcher: CodexRolloutDirectoryWatcher?

    public init(
        accountsRepository: AccountsRepository,
        usageRepository: CodexUsageRepository,
        sessionCoordinator: CodexSessionCoordinator,
        codexHome: URL? = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex", directoryHint: .isDirectory),
        allowsServerProbes: Bool = true,
        pricingDownloader: any OpenAIPricingDownloading = URLSessionOpenAIPricingDownloader()
    ) {
        self.accountsRepository = accountsRepository
        self.usageRepository = usageRepository
        self.sessionCoordinator = sessionCoordinator
        self.codexHome = codexHome
        self.allowsServerProbes = allowsServerProbes
        importer = codexHome.map { CodexRolloutUsageImporter(repository: usageRepository, codexHome: $0) }
        pricingCatalog = OpenAIPricingCatalog(repository: usageRepository, downloader: pricingDownloader)
    }

    public func startLocalHistoryWatcher() {
        guard watcher == nil, let codexHome else { return }
        let watcher = CodexRolloutDirectoryWatcher(codexHome: codexHome) { [weak self] in
            Task { await self?.localFilesChanged() }
        }
        self.watcher = watcher
        watcher.start()
    }

    public func stopLocalHistoryWatcher() {
        watcher?.stop()
        watcher = nil
    }

    public func refresh(
        currentAccountLocalID: UUID?,
        selectedAccountLocalID: UUID?,
        forceAccountIDs: Set<UUID> = [],
        now: Date = .now
    ) async throws -> CodexUsageCoordinatorSnapshot {
        let intent = RefreshIntent(
            currentAccountLocalID: currentAccountLocalID,
            selectedAccountLocalID: selectedAccountLocalID,
            forceAccountIDs: forceAccountIDs,
            now: now
        )
        return try await refresh(intent)
    }

    public func observeCurrentSession(
        accountID: String?,
        fingerprint: String?,
        observedAt: Date = .now,
        transition: CodexAuthIdentityTransition = .observed
    ) async throws {
        _ = try await usageRepository.open()
        try await usageRepository.recordCurrentAuthIdentity(
            accountID: accountID,
            fingerprint: fingerprint,
            observedAt: observedAt,
            transition: transition
        )
    }

    private func refresh(_ intent: RefreshIntent) async throws -> CodexUsageCoordinatorSnapshot {
        if let operation = refreshOperation {
            let covered = operation.intent.covers(intent)
            do {
                let result = try await operation.task.value
                clearRefreshOperation(id: operation.id)
                if covered { return result }
            } catch {
                clearRefreshOperation(id: operation.id)
                if covered { throw error }
            }
            return try await refresh(intent)
        }

        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performRefresh(
                currentAccountLocalID: intent.currentAccountLocalID,
                selectedAccountLocalID: intent.selectedAccountLocalID,
                forceAccountIDs: intent.forceAccountIDs,
                now: intent.now
            )
        }
        refreshOperation = RefreshOperation(id: id, intent: intent, task: task)
        do {
            let result = try await task.value
            clearRefreshOperation(id: id)
            return result
        } catch {
            clearRefreshOperation(id: id)
            throw error
        }
    }

    public func clearStatistics() async throws -> CodexUsageRepositorySnapshot {
        try await usageRepository.clearUsageHistory(keepRateCards: true)
        return try await usageRepository.snapshot()
    }

    public func cachedData() async throws -> (CodexUsageRepositorySnapshot, OpenAIRateCardRevision) {
        let access = try await usageRepository.open()
        var snapshot = try await usageRepository.snapshot()
        if snapshot.rateCardRevisions.isEmpty, access == .readWrite {
            _ = try await usageRepository.recordRateCardRevision(OpenAIPricingCatalog.bundledRevision)
            snapshot = try await usageRepository.snapshot()
        }
        return (snapshot, snapshot.rateCardRevisions.last ?? OpenAIPricingCatalog.bundledRevision)
    }

    public func ingest(
        _ result: AccountValidationResult,
        observedAt: Date = .now
    ) async throws -> CodexUsageRepositorySnapshot {
        guard let accountID = result.identity.accountId else { return try await usageRepository.snapshot() }
        _ = try await usageRepository.open()
        let previous = try await usageRepository.snapshot()
        try await publish(result, accountID: accountID, observedAt: observedAt, previous: previous)
        return try await usageRepository.snapshot()
    }

    public func reimportHistory() async throws -> CodexUsageRepositorySnapshot {
        if let importer { _ = try await importer.reimportAll() }
        return try await usageRepository.snapshot()
    }

    private func localFilesChanged() async {
        guard refreshOperation == nil, let importer else { return }
        _ = await importer.importChangedFiles()
    }

    private func performRefresh(
        currentAccountLocalID: UUID?,
        selectedAccountLocalID: UUID?,
        forceAccountIDs: Set<UUID>,
        now: Date
    ) async throws -> CodexUsageCoordinatorSnapshot {
        _ = try await usageRepository.open()
        var accountSnapshot = try await accountsRepository.reload()
        var usageSnapshot = try await usageRepository.snapshot()
        var currentValidation: AccountValidationResult?
        let ordered = orderedAccounts(
            accountSnapshot.state.accounts,
            usage: usageSnapshot,
            currentID: currentAccountLocalID,
            selectedID: selectedAccountLocalID
        )

        for sourceAccount in ordered where allowsServerProbes && sourceAccount.status != .needsReauth {
            guard let stableID = sourceAccount.accountId else { continue }
            let foreground = sourceAccount.id == currentAccountLocalID || sourceAccount.id == selectedAccountLocalID
            let force = forceAccountIDs.contains(sourceAccount.id)
            let limitsTTL = foreground ? Self.selectedLimitsTTL : Self.backgroundLimitsTTL
            let usageTTL = foreground ? Self.selectedUsageTTL : Self.backgroundUsageTTL
            let limitsDue = force || endpointIsDue(
                accountID: stableID,
                endpoint: .limits,
                ttl: limitsTTL,
                snapshot: usageSnapshot,
                now: now,
                resetCrossed: hasCrossedReset(accountID: stableID, snapshot: usageSnapshot, now: now)
            )
            let usageDue = force || endpointIsDue(
                accountID: stableID,
                endpoint: .usage,
                ttl: usageTTL,
                snapshot: usageSnapshot,
                now: now,
                resetCrossed: false
            )
            let request = CodexAccountProbeRequest(rateLimits: limitsDue, accountUsage: usageDue)
            guard request != .identity else { continue }

            var identityWasValidated = false
            let isCurrentSession = sourceAccount.id == currentAccountLocalID
            do {
                let result: AccountValidationResult
                if isCurrentSession {
                    guard case .published(let outcome) = try await sessionCoordinator.refreshCurrent(request: request) else {
                        continue
                    }
                    result = outcome.validation
                    currentValidation = result
                } else {
                    let credential = try await accountsRepository.credential(provider: .codex, accountID: sourceAccount.id)
                    guard CodexAuthBlob.fingerprint(for: credential) == sourceAccount.authFingerprint else { continue }
                    result = try await sessionCoordinator.validateStored(authData: credential, request: request)
                }
                guard result.identity.accountId == stableID else {
                    throw CodexAuthSwitchTransactionError.identityMismatch
                }
                identityWasValidated = true

                let currentRepositorySnapshot = try await accountsRepository.reload()
                guard let currentAccount = currentRepositorySnapshot.state.accounts.first(where: { $0.id == sourceAccount.id }),
                      currentAccount.accountId == stableID,
                      currentAccount.authFingerprint == sourceAccount.authFingerprint else { continue }
                let updated = CodexAccountValidationPolicy.applying(result, to: currentAccount, observedAt: now)
                if result.authFingerprint == currentAccount.authFingerprint {
                    accountSnapshot = try await accountsRepository.updateCodexAccount(updated)
                } else {
                    accountSnapshot = try await accountsRepository.saveCodexAccount(updated, credential: result.authData, now: now)
                }
                try await publish(result, accountID: stableID, observedAt: now, previous: usageSnapshot)
                if isCurrentSession {
                    try await usageRepository.recordCurrentAuthIdentity(
                        accountID: stableID,
                        fingerprint: result.authFingerprint,
                        observedAt: now,
                        transition: .observed
                    )
                }
                usageSnapshot = try await usageRepository.snapshot()
            } catch {
                accountSnapshot = identityWasValidated
                    ? try await accountsRepository.reload()
                    : try await markValidationFailure(sourceAccount, error: error, now: now)
                if request.rateLimits {
                    try await recordFailure(accountID: stableID, endpoint: .limits, error: error, now: now, previous: usageSnapshot)
                }
                if request.accountUsage {
                    try await recordFailure(accountID: stableID, endpoint: .usage, error: error, now: now, previous: usageSnapshot)
                }
                usageSnapshot = try await usageRepository.snapshot()
            }
        }

        let pricing = await pricingCatalog.refreshIfNeeded(now: now)
        let importReport = await importer?.importChangedFiles()
        usageSnapshot = try await usageRepository.snapshot()
        accountSnapshot = try await accountsRepository.reload()
        return CodexUsageCoordinatorSnapshot(
            accounts: accountSnapshot,
            usage: usageSnapshot,
            rateCard: pricing.revision,
            priceChange: pricing.priceChange,
            currentValidation: currentValidation,
            importReport: importReport
        )
    }

    private func publish(
        _ result: AccountValidationResult,
        accountID: String,
        observedAt: Date,
        previous: CodexUsageRepositorySnapshot
    ) async throws {
        if result.didRequestRateLimits {
            let old = previous.latestLimits[accountID]
            let snapshot = CodexRateLimitsSnapshot(
                accountID: accountID,
                observedAt: observedAt,
                successfulObservedAt: result.rateLimitError == nil ? observedAt : old?.limitsObservedAt,
                primary: result.rateLimitError == nil ? result.rateLimit : old?.primary,
                byLimitID: result.rateLimitError == nil ? result.rateLimitsByLimitId : old?.byLimitID,
                errorMessage: result.rateLimitError
            )
            try await usageRepository.recordRateLimits(snapshot)
            try await usageRepository.recordLimitObservations(snapshot.observations)
            try await recordEndpointResult(
                accountID: accountID,
                endpoint: .limits,
                errorMessage: result.rateLimitError,
                observedAt: observedAt,
                previous: previous
            )
        }
        if result.didRequestAccountUsage {
            if let accountUsage = result.accountUsage {
                try await usageRepository.recordAccountUsage(accountUsage)
            }
            try await recordEndpointResult(
                accountID: accountID,
                endpoint: .usage,
                errorMessage: result.accountUsageError,
                observedAt: observedAt,
                previous: previous
            )
            if let evidence = result.threadUsageEvidence {
                try await usageRepository.recordThreadUsageEvidence(evidence)
            }
        }
    }

    private func clearRefreshOperation(id: UUID) {
        if refreshOperation?.id == id {
            refreshOperation = nil
        }
    }

    private func recordEndpointResult(
        accountID: String,
        endpoint: CodexUsageEndpointKind,
        errorMessage: String?,
        observedAt: Date,
        previous: CodexUsageRepositorySnapshot
    ) async throws {
        let key = EndpointKey(accountID: accountID, endpoint: endpoint)
        if errorMessage == nil { failureCounts[key] = nil } else { failureCounts[key, default: 0] += 1 }
        try await usageRepository.recordEndpointStatus(
            CodexUsageEndpointStatus(
                accountID: accountID,
                endpoint: endpoint,
                attemptedAt: observedAt,
                successfulAt: errorMessage == nil
                    ? observedAt
                    : previous.endpointStatuses[accountID]?[endpoint]?.successfulAt,
                errorMessage: errorMessage
            )
        )
    }

    private func recordFailure(
        accountID: String,
        endpoint: CodexUsageEndpointKind,
        error: Error,
        now: Date,
        previous: CodexUsageRepositorySnapshot
    ) async throws {
        try await recordEndpointResult(
            accountID: accountID,
            endpoint: endpoint,
            errorMessage: error.localizedDescription,
            observedAt: now,
            previous: previous
        )
    }

    private func markValidationFailure(
        _ source: StoredAccount,
        error: Error,
        now: Date
    ) async throws -> AccountsRepositorySnapshot {
        let latest = try await accountsRepository.reload()
        guard var account = latest.state.accounts.first(where: { $0.id == source.id }),
              account.authFingerprint == source.authFingerprint else { return latest }
        account.updatedAt = now
        account.status = AccountResolution.validationStatus(forErrorMessage: error.localizedDescription)
        account.statusMessage = account.status == .needsReauth
            ? L10n.tr("account.needs_login")
            : L10n.tr("account.validation_failed.message")
        return try await accountsRepository.updateCodexAccount(account)
    }

    private func endpointIsDue(
        accountID: String,
        endpoint: CodexUsageEndpointKind,
        ttl: TimeInterval,
        snapshot: CodexUsageRepositorySnapshot,
        now: Date,
        resetCrossed: Bool
    ) -> Bool {
        if resetCrossed { return true }
        let status = snapshot.endpointStatuses[accountID]?[endpoint]
        if let error = status?.errorMessage, !error.isEmpty, let attemptedAt = status?.attemptedAt {
            let count = max(1, failureCounts[EndpointKey(accountID: accountID, endpoint: endpoint)] ?? 1)
            let backoff = min(Self.maximumBackoff, Self.initialBackoff * pow(2, Double(count - 1)))
            return now.timeIntervalSince(attemptedAt) < 0 || now.timeIntervalSince(attemptedAt) >= backoff
        }
        guard let successfulAt = status?.successfulAt else { return true }
        let age = now.timeIntervalSince(successfulAt)
        return age < 0 || age >= ttl
    }

    private func hasCrossedReset(accountID: String, snapshot: CodexUsageRepositorySnapshot, now: Date) -> Bool {
        guard let limits = snapshot.latestLimits[accountID] else { return true }
        return CodexRefreshPolicy.snapshotHasPassedReset(
            primary: limits.primary,
            byLimitId: limits.byLimitID,
            now: now
        )
    }

    private func orderedAccounts(
        _ accounts: [StoredAccount],
        usage: CodexUsageRepositorySnapshot,
        currentID: UUID?,
        selectedID: UUID?
    ) -> [StoredAccount] {
        accounts.sorted { left, right in
            let leftRank = left.id == currentID ? 0 : left.id == selectedID ? 1 : 2
            let rightRank = right.id == currentID ? 0 : right.id == selectedID ? 1 : 2
            if leftRank != rightRank { return leftRank < rightRank }
            let leftAttempt = left.accountId.flatMap { usage.endpointStatuses[$0]?[.limits]?.attemptedAt } ?? .distantPast
            let rightAttempt = right.accountId.flatMap { usage.endpointStatuses[$0]?[.limits]?.attemptedAt } ?? .distantPast
            if leftAttempt != rightAttempt { return leftAttempt < rightAttempt }
            return left.label.localizedCaseInsensitiveCompare(right.label) == .orderedAscending
        }
    }
}
