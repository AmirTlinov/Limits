import Foundation
import LimitsShared

public enum CodexAccountServiceError: LocalizedError {
    case missingAuthFile
    case unsupportedLoginFlow
    case malformedAccountPayload

    public var errorDescription: String? {
        switch self {
        case .missingAuthFile:
            return L10n.tr("codex.account.auth_missing")
        case .unsupportedLoginFlow:
            return L10n.tr("codex.account.login_unsupported")
        case .malformedAccountPayload:
            return L10n.tr("codex.account.payload_malformed")
        }
    }
}

public struct CodexAccountService: @unchecked Sendable {
    private let fileManager: FileManager = .default

    public init() {}

    public func loginNewAccount(openURL: @MainActor @escaping @Sendable (URL) -> Void) async throws -> AccountValidationResult {
        let executable = try CodexExecutableLocator.locate()
        let tempHome = try makeTemporaryCodexHome()
        defer { try? fileManager.removeItem(at: tempHome) }

        let transport = try CodexAppServerTransport(
            executableURL: executable.executableURL,
            codexHome: tempHome,
            environment: executable.environment
        )
        defer { transport.close() }

        try await transport.initialize()
        let login = try await transport.startChatGPTLogin()

        if let authURL = login.authUrl, let url = URL(string: authURL) {
            await openURL(url)
        } else if let verificationURL = login.verificationUrl, let url = URL(string: verificationURL) {
            await openURL(url)
        } else {
            throw CodexAccountServiceError.unsupportedLoginFlow
        }

        guard let loginId = login.loginId else {
            throw CodexAccountServiceError.unsupportedLoginFlow
        }

        do {
            _ = try await withTaskCancellationHandler {
                try await transport.waitForLoginCompletion(loginId: loginId)
            } onCancel: {
                Task {
                    try? await transport.cancelLogin(loginId: loginId)
                    transport.close()
                }
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        return try await captureValidationResult(from: tempHome, transport: transport)
    }

    public func validate(authData: Data) async throws -> AccountValidationResult {
        let executable = try CodexExecutableLocator.locate()
        let tempHome = try makeTemporaryCodexHome()
        defer { try? fileManager.removeItem(at: tempHome) }

        try materializeAuth(authData, in: tempHome)

        let transport = try CodexAppServerTransport(
            executableURL: executable.executableURL,
            codexHome: tempHome,
            environment: executable.environment
        )
        defer { transport.close() }

        try await transport.initialize()
        return try await captureValidationResult(from: tempHome, transport: transport)
    }

    private func captureValidationResult(from codexHome: URL, transport: CodexAppServerTransport) async throws -> AccountValidationResult {
        let accountResponse = try await transport.readAccount(refreshToken: true)
        let rateLimitsResponse: AppServerRateLimitsResponse?
        let rateLimitError: String?
        do {
            rateLimitsResponse = try await transport.readRateLimits()
            rateLimitError = nil
        } catch {
            rateLimitsResponse = nil
            rateLimitError = error.localizedDescription
        }
        let authURL = codexHome.appending(path: "auth.json")
        guard fileManager.fileExists(atPath: authURL.path) else {
            throw CodexAccountServiceError.missingAuthFile
        }

        let authData = try Data(contentsOf: authURL)
        let identity = try CodexAuthBlob.identity(from: authData)

        let resolved = try Self.resolveValidatedIdentity(
            account: accountResponse.account,
            identity: identity,
            rateLimitsResponse: rateLimitsResponse
        )

        return AccountValidationResult(
            authData: authData,
            authFingerprint: CodexAuthBlob.fingerprint(for: authData),
            identity: identity,
            email: resolved.email,
            planType: resolved.planType,
            rateLimit: rateLimitsResponse?.preferredSnapshot,
            rateLimitsByLimitId: rateLimitsResponse?.rateLimitsByLimitId,
            rateLimitError: rateLimitError
        )
    }

    static func resolveValidatedIdentity(
        account: AppServerAccountPayload?,
        identity: AuthIdentity,
        rateLimitsResponse: AppServerRateLimitsResponse?
    ) throws -> (email: String, planType: String) {
        if let account {
            guard account.type == "chatgpt" else {
                throw CodexAccountServiceError.malformedAccountPayload
            }

            guard let email = account.email ?? identity.email, !email.isEmpty else {
                throw CodexAccountServiceError.malformedAccountPayload
            }

            return (email, account.planType ?? rateLimitsResponse?.preferredSnapshot.planType ?? "unknown")
        }

        guard let email = identity.email, !email.isEmpty else {
            throw CodexAccountServiceError.malformedAccountPayload
        }

        return (email, rateLimitsResponse?.preferredSnapshot.planType ?? "unknown")
    }

    private func makeTemporaryCodexHome() throws -> URL {
        let temp = fileManager.temporaryDirectory.appending(path: "limits-codex-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temp.path)
        return temp
    }

    private func materializeAuth(_ data: Data, in codexHome: URL) throws {
        let authURL = codexHome.appending(path: "auth.json")
        try data.write(to: authURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    }
}
