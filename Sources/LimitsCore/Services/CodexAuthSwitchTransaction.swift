import Foundation
import LimitsShared

public enum CodexAuthSwitchTransactionError: LocalizedError, Equatable {
    case missingStableIdentity
    case identityMismatch
    case rollbackFailed(primary: String, rollback: String)

    public var errorDescription: String? {
        switch self {
        case .missingStableIdentity:
            return L10n.tr("account.switch.identity_missing")
        case .identityMismatch:
            return L10n.tr("account.switch.identity_mismatch")
        case .rollbackFailed(let primary, let rollback):
            return L10n.tr("account.switch.rollback_failed", primary, rollback)
        }
    }
}

public protocol CodexAccountValidating: Sendable {
    func validate(authData: Data) async throws -> AccountValidationResult
    func validate(authData: Data, request: CodexAccountProbeRequest) async throws -> AccountValidationResult
}

public extension CodexAccountValidating {
    func validate(authData: Data, request: CodexAccountProbeRequest) async throws -> AccountValidationResult {
        try await validate(authData: authData)
    }
}

extension CodexAccountService: CodexAccountValidating {}

public struct CodexAuthSwitchTransaction: Sendable {
    private let globalStore: any GlobalCodexAuthStoring
    private let validator: any CodexAccountValidating

    public init(
        globalStore: any GlobalCodexAuthStoring,
        validator: any CodexAccountValidating
    ) {
        self.globalStore = globalStore
        self.validator = validator
    }

    public func execute(
        account: StoredAccount,
        authData: Data,
        prepareCommit: @Sendable (AccountValidationResult) async throws -> Void = { _ in }
    ) async throws -> AccountValidationResult {
        let original = try globalStore.readSnapshot()
        let sourceIdentity = try CodexAuthBlob.identity(from: authData)
        let expectedIdentity = account.stableIdentity ?? sourceIdentity.stableIdentity
        guard let expectedIdentity else {
            throw CodexAuthSwitchTransactionError.missingStableIdentity
        }

        let result = try await validator.validate(authData: authData)
        guard result.identity.stableIdentity == expectedIdentity else {
            throw CodexAuthSwitchTransactionError.identityMismatch
        }
        guard try CodexAuthBlob.identity(from: result.authData).stableIdentity == expectedIdentity else {
            throw CodexAuthSwitchTransactionError.identityMismatch
        }

        try await prepareCommit(result)

        do {
            try globalStore.commit(expected: original, replacement: result.authData)
            try globalStore.verifyCommitted(result.authData)
        } catch {
            try rollback(original: original, replacement: result.authData, primary: error)
        }

        return result
    }

    private func rollback(
        original: GlobalCodexAuthSnapshot,
        replacement: Data,
        primary: Error
    ) throws -> Never {
        do {
            try globalStore.restore(original, replacing: replacement)
        } catch GlobalCodexAuthServiceError.concurrentModification {
            throw GlobalCodexAuthServiceError.concurrentModification
        } catch {
            throw CodexAuthSwitchTransactionError.rollbackFailed(
                primary: primary.localizedDescription,
                rollback: error.localizedDescription
            )
        }
        throw primary
    }
}
