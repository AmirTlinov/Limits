import Foundation
import LimitsShared

public protocol CodexLoginServicing: CodexAccountValidating {
    func loginNewAccount(openURL: @MainActor @escaping @Sendable (URL) -> Void) async throws -> AccountValidationResult
}

extension CodexAccountService: CodexLoginServicing {}

public enum CodexSessionCoordinatorError: LocalizedError, Equatable {
    case sessionChanged

    public var errorDescription: String? {
        L10n.tr("account.switch.concurrent_change")
    }
}

public struct CodexSessionObservation: Sendable {
    public let source: CodexSessionSource
    public let authFingerprint: String?
    public let accountID: String?
    public let authMode: String?

    public init(source: CodexSessionSource, authFingerprint: String?, accountID: String?, authMode: String?) {
        self.source = source
        self.authFingerprint = authFingerprint
        self.accountID = accountID
        self.authMode = authMode
    }
}

public struct CodexSessionResult: Sendable {
    public let operationEpoch: UInt64
    public let sourceAuthFingerprint: String
    public let validation: AccountValidationResult
}

@frozen public enum CodexSessionRefreshOutcome: Sendable {
    case published(CodexSessionResult)
    case superseded
}

public actor CodexSessionCoordinator {
    private struct RefreshOperation {
        let id: UUID
        let fingerprint: String
        let request: CodexAccountProbeRequest
        let task: Task<CodexSessionRefreshOutcome, Error>
    }

    private let globalStore: any GlobalCodexAuthStoring
    private let accountService: any CodexLoginServicing
    private var operationEpoch: UInt64 = 0
    private var observedFingerprint: String?
    private var refreshOperation: RefreshOperation?
    private var cancellableOperation: Task<AccountValidationResult, Error>?
    private var cancellableRequestPending = false
    private var cancellationRequested = false
    private var operationInFlight = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        globalStore: any GlobalCodexAuthStoring = GlobalCodexAuthService(),
        accountService: any CodexLoginServicing = CodexAccountService()
    ) {
        self.globalStore = globalStore
        self.accountService = accountService
    }

    public func currentAuthFingerprint() throws -> String? {
        try globalStore.readSnapshot().fingerprint
    }

    public func observeCurrent(accounts: [StoredAccount]) throws -> CodexSessionObservation {
        let snapshot = try globalStore.readSnapshot()
        guard let authData = snapshot.data else {
            return CodexSessionObservation(source: .missing, authFingerprint: nil, accountID: nil, authMode: nil)
        }
        let identity = try CodexAuthBlob.identity(from: authData)
        let fingerprint = CodexAuthBlob.fingerprint(for: authData)
        let source: CodexSessionSource
        if let matched = AccountResolution.storedCodexMatch(identity: identity, fingerprint: fingerprint, accounts: accounts) {
            source = .stored(matched.id)
        } else {
            source = .external(identity.accountId)
        }
        observe(fingerprint)
        return CodexSessionObservation(
            source: source,
            authFingerprint: fingerprint,
            accountID: identity.accountId,
            authMode: identity.authMode
        )
    }

    public func refreshCurrent(request: CodexAccountProbeRequest = .all) async throws -> CodexSessionRefreshOutcome {
        let snapshot = try globalStore.readSnapshot()
        guard let authData = snapshot.data else {
            throw GlobalCodexAuthServiceError.missingAuthFile
        }
        let fingerprint = CodexAuthBlob.fingerprint(for: authData)
        observe(fingerprint)

        if let refreshOperation,
           refreshOperation.fingerprint == fingerprint,
           refreshOperation.request.covers(request) {
            return try await refreshOperation.task.value
        }

        let id = UUID()
        let epoch = operationEpoch
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performRefresh(
                snapshot: snapshot,
                authData: authData,
                fingerprint: fingerprint,
                request: request,
                epoch: epoch
            )
        }
        refreshOperation = RefreshOperation(id: id, fingerprint: fingerprint, request: request, task: task)
        do {
            let result = try await task.value
            clearRefresh(id: id)
            return result
        } catch {
            clearRefresh(id: id)
            throw error
        }
    }

    public func validateStored(authData: Data) async throws -> AccountValidationResult {
        try await validateStored(authData: authData, request: .all)
    }

    public func validateStored(
        authData: Data,
        request: CodexAccountProbeRequest
    ) async throws -> AccountValidationResult {
        await beginExclusiveOperation()
        defer { finishExclusiveOperation() }
        return try await accountService.validate(authData: authData, request: request)
    }

    public func loginNewAccount(
        openURL: @MainActor @escaping @Sendable (URL) -> Void
    ) async throws -> AccountValidationResult {
        cancellableRequestPending = true
        await beginExclusiveOperation()
        defer {
            cancellableRequestPending = false
            cancellationRequested = false
            finishExclusiveOperation()
        }
        if cancellationRequested { throw CancellationError() }
        let task = Task { try await accountService.loginNewAccount(openURL: openURL) }
        cancellableOperation = task
        defer { cancellableOperation = nil }
        return try await task.value
    }

    public func cancelCurrentOperation() {
        if let cancellableOperation {
            cancellableOperation.cancel()
        } else if cancellableRequestPending {
            cancellationRequested = true
        }
    }

    public func switchAccount(
        _ account: StoredAccount,
        authData: Data,
        prepareCommit: @escaping @Sendable (AccountValidationResult) async throws -> Void = { _ in }
    ) async throws -> CodexSessionResult {
        operationEpoch &+= 1
        observedFingerprint = nil
        await beginExclusiveOperation()
        defer { finishExclusiveOperation() }

        let transaction = CodexAuthSwitchTransaction(globalStore: globalStore, validator: accountService)
        let validation = try await transaction.execute(account: account, authData: authData, prepareCommit: prepareCommit)
        let sourceFingerprint = CodexAuthBlob.fingerprint(for: authData)
        let fingerprint = validation.authFingerprint
        operationEpoch &+= 1
        observedFingerprint = fingerprint
        return CodexSessionResult(
            operationEpoch: operationEpoch,
            sourceAuthFingerprint: sourceFingerprint,
            validation: validation
        )
    }

    private func performRefresh(
        snapshot: GlobalCodexAuthSnapshot,
        authData: Data,
        fingerprint: String,
        request: CodexAccountProbeRequest,
        epoch: UInt64
    ) async throws -> CodexSessionRefreshOutcome {
        await beginExclusiveOperation()
        defer { finishExclusiveOperation() }
        let validation = try await accountService.validate(authData: authData, request: request)
        let sourceIdentity = try CodexAuthBlob.identity(from: authData).stableIdentity
        guard sourceIdentity != nil, validation.identity.stableIdentity == sourceIdentity else {
            throw CodexAuthSwitchTransactionError.identityMismatch
        }
        let beforeCommit = try globalStore.readSnapshot()
        guard operationEpoch == epoch, observedFingerprint == fingerprint, beforeCommit == snapshot else {
            return .superseded
        }
        if validation.authFingerprint != fingerprint {
            try globalStore.commit(expected: snapshot, replacement: validation.authData)
            try globalStore.verifyCommitted(validation.authData)
            observedFingerprint = validation.authFingerprint
        }
        let current = try globalStore.readSnapshot().data.map { CodexAuthBlob.fingerprint(for: $0) }
        guard operationEpoch == epoch, current == validation.authFingerprint else { return .superseded }
        return .published(
            CodexSessionResult(
                operationEpoch: epoch,
                sourceAuthFingerprint: fingerprint,
                validation: validation
            )
        )
    }

    private func observe(_ fingerprint: String) {
        if observedFingerprint != fingerprint {
            observedFingerprint = fingerprint
            operationEpoch &+= 1
        }
    }

    private func clearRefresh(id: UUID) {
        if refreshOperation?.id == id {
            refreshOperation = nil
        }
    }

    private func beginExclusiveOperation() async {
        if !operationInFlight {
            operationInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func finishExclusiveOperation() {
        if operationWaiters.isEmpty {
            operationInFlight = false
        } else {
            operationWaiters.removeFirst().resume()
        }
    }
}
