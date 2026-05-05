import AppKit
import Foundation

enum CodexAccountServiceError: LocalizedError {
    case missingAuthFile
    case unsupportedLoginFlow
    case malformedAccountPayload
    case missingRateLimits

    var errorDescription: String? {
        switch self {
        case .missingAuthFile:
            return "Codex completed login, but no auth.json was materialized."
        case .unsupportedLoginFlow:
            return "Codex returned an unsupported login flow."
        case .malformedAccountPayload:
            return "Codex did not return a usable ChatGPT account payload."
        case .missingRateLimits:
            return "Codex did not return usable live rate limits."
        }
    }
}

struct CodexAccountService: @unchecked Sendable {
    private let fileManager: FileManager = .default
    private let authService = GlobalCodexAuthService()

    func loginNewAccount(openURL: @MainActor @escaping (URL) -> Void) async throws -> AccountValidationResult {
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

        _ = try await transport.waitForLoginCompletion(loginId: loginId)
        return try await captureValidationResult(from: tempHome, transport: transport)
    }

    func validate(authData: Data) async throws -> AccountValidationResult {
        let executable = try CodexExecutableLocator.locate()
        let tempHome = try makeTemporaryCodexHome()
        defer { try? fileManager.removeItem(at: tempHome) }

        try authService.materializeAuth(authData, in: tempHome)

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
        let accountResponse = try? await transport.readAccount(refreshToken: true)
        let rateLimitsResponse = try await transport.readRateLimits()
        let authURL = codexHome.appending(path: "auth.json")
        guard fileManager.fileExists(atPath: authURL.path) else {
            throw CodexAccountServiceError.missingAuthFile
        }

        let authData = try Data(contentsOf: authURL)
        let identity = try CodexAuthBlob.identity(from: authData)

        let resolved = try Self.resolveValidatedIdentity(
            account: accountResponse?.account,
            identity: identity,
            rateLimitsResponse: rateLimitsResponse
        )

        return AccountValidationResult(
            authData: authData,
            authFingerprint: CodexAuthBlob.fingerprint(for: authData),
            identity: identity,
            email: resolved.email,
            planType: resolved.planType,
            rateLimit: rateLimitsResponse.preferredSnapshot,
            rateLimitsByLimitId: rateLimitsResponse.rateLimitsByLimitId
        )
    }

    static func resolveValidatedIdentity(
        account: AppServerAccountPayload?,
        identity: AuthIdentity,
        rateLimitsResponse: AppServerRateLimitsResponse?
    ) throws -> (email: String, planType: String) {
        guard let rateLimitsResponse else {
            throw CodexAccountServiceError.missingRateLimits
        }

        if let account {
            guard account.type == "chatgpt" else {
                throw CodexAccountServiceError.malformedAccountPayload
            }

            guard let email = account.email ?? identity.email, !email.isEmpty else {
                throw CodexAccountServiceError.malformedAccountPayload
            }

            return (email, account.planType ?? rateLimitsResponse.preferredSnapshot.planType ?? "unknown")
        }

        guard let email = identity.email, !email.isEmpty else {
            throw CodexAccountServiceError.malformedAccountPayload
        }

        return (email, rateLimitsResponse.preferredSnapshot.planType ?? "unknown")
    }

    private func makeTemporaryCodexHome() throws -> URL {
        let temp = fileManager.temporaryDirectory.appending(path: "limits-codex-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: temp, withIntermediateDirectories: true, attributes: nil)
        return temp
    }
}
