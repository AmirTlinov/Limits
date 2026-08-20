import Foundation
import LimitsShared

public enum ClaudeCredentialSwitchTransactionError: LocalizedError, Equatable {
    case missingStableIdentity
    case identityMismatch
    case notLoggedIn
    case rollbackFailed(primary: String, rollback: String)

    public var errorDescription: String? {
        switch self {
        case .missingStableIdentity:
            return L10n.tr("claude.switch.identity_missing")
        case .identityMismatch:
            return L10n.tr("claude.switch.identity_mismatch")
        case .notLoggedIn:
            return L10n.tr("claude.not_logged_in.error")
        case .rollbackFailed(let primary, let rollback):
            return L10n.tr("claude.switch.rollback_failed", primary, rollback)
        }
    }
}

public protocol ClaudeAuthStatusReading: Sendable {
    func readStatus() async throws -> ClaudeAuthStatus
}

extension ClaudeAuthStatusService: ClaudeAuthStatusReading {}

public struct ClaudeCredentialSwitchResult: Sendable {
    public let credential: Data
    public let status: ClaudeAuthStatus

    public init(credential: Data, status: ClaudeAuthStatus) {
        self.credential = credential
        self.status = status
    }
}

public struct ClaudeCredentialSwitchTransaction: Sendable {
    private let globalStore: any GlobalClaudeCredentialStoring
    private let statusReader: any ClaudeAuthStatusReading

    public init(
        globalStore: any GlobalClaudeCredentialStoring,
        statusReader: any ClaudeAuthStatusReading
    ) {
        self.globalStore = globalStore
        self.statusReader = statusReader
    }

    public func execute(
        account: ClaudeStoredAccount,
        credential: Data,
        prepareCommit: @Sendable (ClaudeCredentialSwitchResult) async throws -> Void = { _ in }
    ) async throws -> ClaudeCredentialSwitchResult {
        guard let expectedIdentity = account.stableIdentity else {
            throw ClaudeCredentialSwitchTransactionError.missingStableIdentity
        }

        let original = try globalStore.readSnapshot()
        do {
            try globalStore.commit(expected: original, replacement: credential)
            try globalStore.verifyCommitted(credential, basedOn: original)
        } catch {
            try rollback(original: original, replacement: credential, primary: error)
        }

        var status: ClaudeAuthStatus
        do {
            status = try await statusReader.readStatus()
        } catch {
            try rollbackUnlessExternallyChanged(original: original, replacement: credential, primary: error)
        }

        guard status.loggedIn else {
            try rollbackUnlessExternallyChanged(
                original: original,
                replacement: credential,
                primary: ClaudeCredentialSwitchTransactionError.notLoggedIn
            )
        }
        guard expectedIdentity.matches(status.stableIdentity) else {
            try rollbackUnlessExternallyChanged(
                original: original,
                replacement: credential,
                primary: ClaudeCredentialSwitchTransactionError.identityMismatch
            )
        }

        var committed = try globalStore.readSnapshot()
        guard
            committed.account == (original.account ?? NSUserName()),
            let initialCommittedCredential = committed.data
        else {
            try rollbackUnlessExternallyChanged(
                original: original,
                replacement: credential,
                primary: GlobalClaudeCredentialServiceError.committedDataMismatch
            )
        }

        if initialCommittedCredential != credential {
            let refreshedStatus = try await statusReader.readStatus()
            let confirmed = try globalStore.readSnapshot()
            guard confirmed == committed else {
                throw GlobalClaudeCredentialServiceError.concurrentModification
            }
            guard refreshedStatus.loggedIn, expectedIdentity.matches(refreshedStatus.stableIdentity) else {
                throw GlobalClaudeCredentialServiceError.concurrentModification
            }
            status = refreshedStatus
            committed = confirmed
        }

        guard let committedCredential = committed.data else {
            throw GlobalClaudeCredentialServiceError.committedDataMismatch
        }

        let result = ClaudeCredentialSwitchResult(credential: committedCredential, status: status)
        do {
            try await prepareCommit(result)
        } catch {
            if committedCredential == credential {
                try rollback(original: original, replacement: credential, primary: error)
            }
            throw error
        }
        return result
    }

    private func rollbackUnlessExternallyChanged(
        original: GlobalClaudeCredentialSnapshot,
        replacement: Data,
        primary: Error
    ) throws -> Never {
        let current = try globalStore.readSnapshot()
        guard current.data == replacement || current == original else {
            throw GlobalClaudeCredentialServiceError.concurrentModification
        }
        try rollback(original: original, replacement: replacement, primary: primary)
    }

    private func rollback(
        original: GlobalClaudeCredentialSnapshot,
        replacement: Data,
        primary: Error
    ) throws -> Never {
        do {
            try globalStore.restore(original, replacing: replacement)
        } catch GlobalClaudeCredentialServiceError.concurrentModification {
            throw GlobalClaudeCredentialServiceError.concurrentModification
        } catch {
            throw ClaudeCredentialSwitchTransactionError.rollbackFailed(
                primary: primary.localizedDescription,
                rollback: error.localizedDescription
            )
        }
        throw primary
    }
}

private extension ClaudeAccountIdentity {
    func matches(_ other: ClaudeAccountIdentity?) -> Bool {
        guard let other, normalizedEmail == other.normalizedEmail else {
            return false
        }
        return organizationId == nil || organizationId == other.organizationId
    }
}
