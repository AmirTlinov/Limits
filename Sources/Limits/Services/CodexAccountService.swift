import AppKit
import Foundation

enum CodexAccountServiceError: LocalizedError {
    case missingAuthFile
    case unsupportedLoginFlow
    case malformedAccountPayload

    var errorDescription: String? {
        switch self {
        case .missingAuthFile:
            return "Codex completed login, but no auth.json was materialized."
        case .unsupportedLoginFlow:
            return "Codex returned an unsupported login flow."
        case .malformedAccountPayload:
            return "Codex did not return a usable ChatGPT account payload."
        }
    }
}

struct CodexAccountService: @unchecked Sendable {
    private let fileManager: FileManager = .default
    private let authService = GlobalCodexAuthService()

    func loginNewAccount(openURL: @MainActor @escaping (URL) -> Void) async throws -> AccountValidationResult {
        let executableURL = try CodexExecutableLocator.locate()
        let tempHome = try makeTemporaryCodexHome()
        defer { try? fileManager.removeItem(at: tempHome) }

        let transport = try CodexAppServerTransport(executableURL: executableURL, codexHome: tempHome)
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
        let executableURL = try CodexExecutableLocator.locate()
        let tempHome = try makeTemporaryCodexHome()
        defer { try? fileManager.removeItem(at: tempHome) }

        try authService.materializeAuth(authData, in: tempHome)

        let transport = try CodexAppServerTransport(executableURL: executableURL, codexHome: tempHome)
        defer { transport.close() }

        try await transport.initialize()
        return try await captureValidationResult(from: tempHome, transport: transport)
    }

    private func captureValidationResult(from codexHome: URL, transport: CodexAppServerTransport) async throws -> AccountValidationResult {
        let accountResponse = try await transport.readAccount(refreshToken: true)
        guard
            let account = accountResponse.account,
            account.type == "chatgpt",
            let email = account.email
        else {
            throw CodexAccountServiceError.malformedAccountPayload
        }

        let rateLimitsResponse = try? await transport.readRateLimits()
        let authURL = codexHome.appending(path: "auth.json")
        guard fileManager.fileExists(atPath: authURL.path) else {
            throw CodexAccountServiceError.missingAuthFile
        }

        let authData = try Data(contentsOf: authURL)
        let identity = try CodexAuthBlob.identity(from: authData)

        return AccountValidationResult(
            authData: authData,
            authFingerprint: CodexAuthBlob.fingerprint(for: authData),
            identity: identity,
            email: email,
            planType: account.planType ?? "unknown",
            rateLimit: rateLimitsResponse?.preferredSnapshot,
            rateLimitsByLimitId: rateLimitsResponse?.rateLimitsByLimitId
        )
    }

    private func makeTemporaryCodexHome() throws -> URL {
        let temp = fileManager.temporaryDirectory.appending(path: "limits-codex-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: temp, withIntermediateDirectories: true, attributes: nil)
        return temp
    }
}
