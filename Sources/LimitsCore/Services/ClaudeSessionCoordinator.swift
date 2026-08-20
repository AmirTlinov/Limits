import Foundation
import LimitsShared

public protocol ClaudeSessionStatusReading: ClaudeAuthStatusReading {
    func isInstalled() -> Bool
}

extension ClaudeAuthStatusService: ClaudeSessionStatusReading {}

public struct ClaudeLiveEvidence: Sendable, Hashable {
    public let identity: ClaudeAccountIdentity
    public let identityChangedAt: Date
    public let snapshot: ClaudeStatuslineBridgeSnapshot
    public let snapshotAt: Date

    public init(identity: ClaudeAccountIdentity, identityChangedAt: Date, snapshot: ClaudeStatuslineBridgeSnapshot, snapshotAt: Date) {
        self.identity = identity
        self.identityChangedAt = identityChangedAt
        self.snapshot = snapshot
        self.snapshotAt = snapshotAt
    }
}

public struct ClaudeSessionProbeResult: Sendable {
    public let source: ClaudeSessionSource
    public let status: ClaudeAuthStatus?
    public let validatedAt: Date?
    public let globalCredentialFingerprint: String?
    public let evidence: ClaudeLiveEvidence?
    public let bridgeStatus: ClaudeStatuslineBridgeStatus
    public let repositorySnapshot: AccountsRepositorySnapshot
    public let repositoryError: String?
}

public struct ClaudeCredentialCapture: Sendable {
    public let credential: Data
    public let status: ClaudeAuthStatus
}

public actor ClaudeSessionCoordinator {
    private let globalStore: any GlobalClaudeCredentialStoring
    private let statusReader: any ClaudeSessionStatusReading
    private let repository: AccountsRepository
    private let bridge: ClaudeStatuslineBridgeService
    private let evidenceTTL: TimeInterval
    private var currentIdentity: ClaudeAccountIdentity?
    private var identityChangedAt = Date.distantPast
    private var operationInFlight = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        globalStore: any GlobalClaudeCredentialStoring = GlobalClaudeCredentialService(),
        statusReader: any ClaudeSessionStatusReading = ClaudeAuthStatusService(),
        repository: AccountsRepository,
        bridge: ClaudeStatuslineBridgeService = ClaudeStatuslineBridgeService(),
        evidenceTTL: TimeInterval = LimitsFreshnessPolicy.defaultTTL
    ) {
        self.globalStore = globalStore
        self.statusReader = statusReader
        self.repository = repository
        self.bridge = bridge
        self.evidenceTTL = evidenceTTL
    }

    public func currentCredentialFingerprint() throws -> String? {
        try globalStore.readSnapshot().fingerprint
    }

    public func probe(now: Date = .now) async throws -> ClaudeSessionProbeResult {
        await beginExclusiveOperation()
        defer { finishExclusiveOperation() }

        var repositorySnapshot = try await repository.reload()
        guard statusReader.isInstalled() else {
            transitionIdentity(to: nil, at: now)
            try? bridge.clearSnapshot()
            return ClaudeSessionProbeResult(
                source: .notInstalled,
                status: nil,
                validatedAt: nil,
                globalCredentialFingerprint: nil,
                evidence: nil,
                bridgeStatus: (try? bridge.bridgeStatus()) ?? emptyBridgeStatus,
                repositorySnapshot: repositorySnapshot,
                repositoryError: nil
            )
        }

        let credentialBefore = try globalStore.readSnapshot()
        let statusBefore = try await statusReader.readStatus()
        let credentialAfter = try globalStore.readSnapshot()
        let validatedAt = now

        guard statusBefore.loggedIn, let identity = statusBefore.stableIdentity else {
            transitionIdentity(to: nil, at: now)
            try? bridge.clearSnapshot()
            return ClaudeSessionProbeResult(
                source: .loggedOut,
                status: statusBefore,
                validatedAt: validatedAt,
                globalCredentialFingerprint: nil,
                evidence: nil,
                bridgeStatus: (try? bridge.bridgeStatus()) ?? emptyBridgeStatus,
                repositorySnapshot: repositorySnapshot,
                repositoryError: nil
            )
        }

        transitionIdentity(to: identity, at: now)
        let credential = credentialAfter.data ?? credentialBefore.data
        let fingerprint = credential.map { CodexAuthBlob.fingerprint(for: $0) }
        var repositoryError: String?
        do {
            repositorySnapshot = try await persistCredentialRotation(
                status: statusBefore,
                identity: identity,
                before: credentialBefore,
                after: credentialAfter,
                repositorySnapshot: repositorySnapshot,
                now: now
            )
        } catch {
            repositoryError = error.localizedDescription
        }
        let bridgeStatus = (try? bridge.bridgeStatus()) ?? emptyBridgeStatus
        let evidence = try await boundEvidence(
            statusBefore: statusBefore,
            bridgeStatus: bridgeStatus,
            now: now
        )
        let credentialFinal = try globalStore.readSnapshot()
        do {
            repositorySnapshot = try await persistCredentialRotation(
                status: statusBefore,
                identity: identity,
                before: credentialAfter,
                after: credentialFinal,
                repositorySnapshot: repositorySnapshot,
                now: now
            )
        } catch {
            repositoryError = error.localizedDescription
        }
        let finalFingerprint = credentialFinal.data.map { CodexAuthBlob.fingerprint(for: $0) } ?? fingerprint
        let matched = AccountResolution.storedClaudeMatch(
            identity: identity,
            fingerprint: finalFingerprint,
            accounts: repositorySnapshot.state.claudeAccounts
        )
        let source: ClaudeSessionSource = matched.map { .stored($0.id) } ?? .external(statusBefore.email)

        return ClaudeSessionProbeResult(
            source: source,
            status: statusBefore,
            validatedAt: validatedAt,
            globalCredentialFingerprint: finalFingerprint,
            evidence: evidence,
            bridgeStatus: bridgeStatus,
            repositorySnapshot: repositorySnapshot,
            repositoryError: repositoryError
        )
    }

    public func switchAccount(_ account: ClaudeStoredAccount, now: Date = .now) async throws -> ClaudeSessionProbeResult {
        await beginExclusiveOperation()
        do {
            try? bridge.clearSnapshot()
            transitionIdentity(to: nil, at: now)
            let credential = try await repository.credential(provider: .claude, accountID: account.id)
            let transaction = ClaudeCredentialSwitchTransaction(globalStore: globalStore, statusReader: statusReader)
            _ = try await transaction.execute(account: account, credential: credential) { [repository] result in
                var updated = account
                updated.email = result.status.email ?? account.email
                updated.subscriptionType = result.status.subscriptionType ?? account.subscriptionType
                updated.authMethod = result.status.authMethod
                updated.orgId = result.status.orgId
                updated.orgName = result.status.orgName
                updated.updatedAt = now
                updated.lastValidatedAt = now
                updated.status = .ok
                updated.statusMessage = L10n.tr("claude.account.ready")
                _ = try await repository.saveClaudeAccount(updated, credential: result.credential, now: now)
            }
            finishExclusiveOperation()
            return try await probe(now: now)
        } catch {
            finishExclusiveOperation()
            throw error
        }
    }

    public func captureCurrentCredential() async throws -> ClaudeCredentialCapture {
        await beginExclusiveOperation()
        defer { finishExclusiveOperation() }
        let status = try await statusReader.readStatus()
        guard status.loggedIn, status.stableIdentity != nil else {
            throw ClaudeCredentialSwitchTransactionError.notLoggedIn
        }
        guard let credential = try globalStore.readSnapshot().data else {
            throw GlobalClaudeCredentialServiceError.missingCredential
        }
        return ClaudeCredentialCapture(credential: credential, status: status)
    }

    public func installBridge() throws {
        try bridge.installBridge()
    }

    public func uninstallBridge() throws {
        try bridge.uninstallBridge()
        transitionIdentity(to: currentIdentity, at: .now)
    }

    public func clearEvidence() throws {
        try bridge.clearSnapshot()
    }

    private func boundEvidence(
        statusBefore: ClaudeAuthStatus,
        bridgeStatus: ClaudeStatuslineBridgeStatus,
        now: Date
    ) async throws -> ClaudeLiveEvidence? {
        guard bridgeStatus.installed, bridgeStatus.hasSnapshot else { return nil }
        let payload = try bridge.readSnapshot()
        guard
            LimitsFreshnessPolicy.isFresh(observedAt: payload.updatedAt, at: now, ttl: evidenceTTL),
            payload.updatedAt >= identityChangedAt
        else {
            return nil
        }
        let statusAfter = try await statusReader.readStatus()
        guard
            statusAfter.loggedIn,
            let before = statusBefore.stableIdentity,
            before == statusAfter.stableIdentity,
            before == currentIdentity
        else {
            try? bridge.clearSnapshot()
            return nil
        }
        return ClaudeLiveEvidence(
            identity: before,
            identityChangedAt: identityChangedAt,
            snapshot: payload.snapshot,
            snapshotAt: payload.updatedAt
        )
    }

    private func persistCredentialRotation(
        status: ClaudeAuthStatus,
        identity: ClaudeAccountIdentity,
        before: GlobalClaudeCredentialSnapshot,
        after: GlobalClaudeCredentialSnapshot,
        repositorySnapshot: AccountsRepositorySnapshot,
        now: Date
    ) async throws -> AccountsRepositorySnapshot {
        guard let credential = after.data ?? before.data else { return repositorySnapshot }
        let fingerprint = CodexAuthBlob.fingerprint(for: credential)
        guard let matched = AccountResolution.storedClaudeMatch(
            identity: identity,
            fingerprint: fingerprint,
            accounts: repositorySnapshot.state.claudeAccounts
        ) else {
            return repositorySnapshot
        }
        guard matched.authFingerprint != fingerprint || before != after else { return repositorySnapshot }
        var updated = matched
        updated.email = status.email ?? matched.email
        updated.subscriptionType = status.subscriptionType ?? matched.subscriptionType
        updated.authMethod = status.authMethod
        updated.orgId = status.orgId
        updated.orgName = status.orgName
        updated.updatedAt = now
        updated.lastValidatedAt = now
        updated.status = .ok
        updated.statusMessage = L10n.tr("claude.account.ready")
        return try await repository.saveClaudeAccount(updated, credential: credential, now: now)
    }

    private func transitionIdentity(to identity: ClaudeAccountIdentity?, at date: Date) {
        if currentIdentity != identity {
            currentIdentity = identity
            identityChangedAt = date
        }
    }

    private var emptyBridgeStatus: ClaudeStatuslineBridgeStatus {
        ClaudeStatuslineBridgeStatus(installed: false, hasSnapshot: false, preservingOriginalStatusLine: false)
    }

    private func beginExclusiveOperation() async {
        if !operationInFlight {
            operationInFlight = true
            return
        }
        await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func finishExclusiveOperation() {
        if operationWaiters.isEmpty {
            operationInFlight = false
        } else {
            operationWaiters.removeFirst().resume()
        }
    }
}
