import Foundation
import LimitsShared

public enum CodexAccountServiceError: LocalizedError {
    case missingAuthFile
    case unsupportedLoginFlow
    case malformedAccountPayload
    case malformedUsagePayload

    public var errorDescription: String? {
        switch self {
        case .missingAuthFile:
            return L10n.tr("codex.account.auth_missing")
        case .unsupportedLoginFlow:
            return L10n.tr("codex.account.login_unsupported")
        case .malformedAccountPayload:
            return L10n.tr("codex.account.payload_malformed")
        case .malformedUsagePayload:
            return L10n.tr("codex.account.usage_malformed")
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
        return try await captureValidationResult(from: tempHome, transport: transport, request: .all)
    }

    public func validate(authData: Data) async throws -> AccountValidationResult {
        try await validate(authData: authData, request: .all)
    }

    public func validate(authData: Data, request: CodexAccountProbeRequest) async throws -> AccountValidationResult {
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
        return try await captureValidationResult(from: tempHome, transport: transport, request: request)
    }

    private func captureValidationResult(
        from codexHome: URL,
        transport: CodexAppServerTransport,
        request: CodexAccountProbeRequest
    ) async throws -> AccountValidationResult {
        let accountResponse = try await transport.readAccount(refreshToken: true)
        let rateLimitsResponse: AppServerRateLimitsResponse?
        let rateLimitError: String?
        let usageResponse: AppServerAccountUsageResponse?
        let usageError: String?
        async let rateLimitsAttempt: Result<AppServerRateLimitsResponse, Error>? = request.rateLimits
            ? Self.captureRateLimits(transport) : nil
        async let usageAttempt: Result<AppServerAccountUsageResponse, Error>? = request.accountUsage
            ? Self.captureUsage(transport) : nil
        let rateLimitsResult = await rateLimitsAttempt
        let usageResult = await usageAttempt
        switch rateLimitsResult {
        case .success(let response):
            rateLimitsResponse = response
            rateLimitError = nil
        case .failure(let error):
            rateLimitsResponse = nil
            rateLimitError = error.localizedDescription
        case nil:
            rateLimitsResponse = nil
            rateLimitError = nil
        }
        switch usageResult {
        case .success(let response):
            usageResponse = response
            usageError = nil
        case .failure(let error):
            usageResponse = nil
            usageError = error.localizedDescription
        case nil:
            usageResponse = nil
            usageError = nil
        }
        let authURL = codexHome.appending(path: "auth.json")
        guard fileManager.fileExists(atPath: authURL.path) else {
            throw CodexAccountServiceError.missingAuthFile
        }

        let authData = try Data(contentsOf: authURL)
        let authMetadata = try CodexAuthBlob.metadata(from: authData)
        let identity = authMetadata.identity

        let resolved = try Self.resolveValidatedIdentity(
            account: accountResponse.account,
            identity: identity,
            authPlanType: authMetadata.planType,
            rateLimitsResponse: rateLimitsResponse
        )
        let accountUsage: CodexAccountUsageSnapshot?
        var resolvedUsageError = usageError
        if let usageResponse, let accountID = identity.accountId {
            do {
                accountUsage = try Self.makeUsageSnapshot(usageResponse, accountID: accountID, observedAt: .now)
            } catch {
                accountUsage = nil
                resolvedUsageError = error.localizedDescription
            }
        } else {
            accountUsage = nil
        }
        let threadUsageEvidence = identity.accountId.flatMap { accountID in
            usageResponse?.threadUsage.map {
                Self.makeThreadUsageEvidence($0, accountID: accountID, observedAt: .now)
            }
        }

        return AccountValidationResult(
            authData: authData,
            authFingerprint: CodexAuthBlob.fingerprint(for: authData),
            identity: identity,
            email: resolved.email,
            planType: resolved.planType,
            rateLimit: rateLimitsResponse?.preferredSnapshot,
            rateLimitsByLimitId: rateLimitsResponse?.rateLimitsByLimitId,
            rateLimitError: rateLimitError,
            didRequestRateLimits: request.rateLimits,
            accountUsage: accountUsage,
            accountUsageError: resolvedUsageError,
            didRequestAccountUsage: request.accountUsage,
            threadUsageEvidence: threadUsageEvidence,
            subscriptionPeriod: authMetadata.subscriptionPeriod
        )
    }

    private static func captureRateLimits(
        _ transport: CodexAppServerTransport
    ) async -> Result<AppServerRateLimitsResponse, Error> {
        do { return .success(try await transport.readRateLimits()) }
        catch { return .failure(error) }
    }

    private static func captureUsage(
        _ transport: CodexAppServerTransport
    ) async -> Result<AppServerAccountUsageResponse, Error> {
        do { return .success(try await transport.readAccountUsage()) }
        catch { return .failure(error) }
    }

    static func makeUsageSnapshot(
        _ response: AppServerAccountUsageResponse,
        accountID: String,
        observedAt: Date
    ) throws -> CodexAccountUsageSnapshot {
        let daily = (response.dailyUsageBuckets ?? []).compactMap { bucket -> CodexDailyTokenActivity? in
            guard let date = parseUTCDay(bucket.startDate) else { return nil }
            return CodexDailyTokenActivity(date: date, tokens: bucket.tokens)
        }
        guard response.dailyUsageBuckets == nil || daily.count == response.dailyUsageBuckets?.count else {
            throw CodexAccountServiceError.malformedUsagePayload
        }
        return CodexAccountUsageSnapshot(
            accountID: accountID,
            observedAt: observedAt,
            summary: CodexAccountUsageSummary(
                lifetimeTokens: response.summary.lifetimeTokens,
                peakDailyTokens: response.summary.peakDailyTokens,
                longestRunningTurnSeconds: response.summary.longestRunningTurnSec,
                currentStreakDays: response.summary.currentStreakDays,
                longestStreakDays: response.summary.longestStreakDays
            ),
            dailyActivity: daily
        )
    }

    static func makeThreadUsageEvidence(
        _ response: AppServerAccountUsageResponse.ThreadUsage,
        accountID: String,
        observedAt: Date
    ) -> CodexThreadUsageEvidence {
        CodexThreadUsageEvidence(
            threadID: response.threadId,
            accountID: accountID,
            observedAt: observedAt,
            estimatedCreditsMicros: response.estimatedUsageCreditsMicros,
            estimatedUSDMicros: response.estimatedUsageUsdMicros,
            groups: response.groups.map { group in
                CodexThreadUsageEvidence.Group(
                    model: group.model,
                    reasoningEffort: group.reasoningEffort,
                    speed: group.speed,
                    usage: CodexTokenUsage(
                        inputTokens: group.inputTokens ?? 0,
                        cachedInputTokens: group.cachedInputTokens ?? 0,
                        cacheWriteInputTokens: 0,
                        outputTokens: group.outputTokens ?? 0,
                        reasoningOutputTokens: 0,
                        totalTokens: group.totalTokens ?? 0
                    ),
                    estimatedCreditsMicros: group.estimatedUsageCreditsMicros
                )
            }
        )
    }

    private static func parseUTCDay(_ value: String) -> Date? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    static func resolveValidatedIdentity(
        account: AppServerAccountPayload?,
        identity: AuthIdentity,
        authPlanType: String? = nil,
        rateLimitsResponse: AppServerRateLimitsResponse?
    ) throws -> (email: String, planType: String) {
        if let account {
            guard account.type == "chatgpt" else {
                throw CodexAccountServiceError.malformedAccountPayload
            }

            guard let email = account.email ?? identity.email, !email.isEmpty else {
                throw CodexAccountServiceError.malformedAccountPayload
            }

            return (email, account.planType ?? authPlanType ?? rateLimitsResponse?.preferredSnapshot.planType ?? "unknown")
        }

        guard let email = identity.email, !email.isEmpty else {
            throw CodexAccountServiceError.malformedAccountPayload
        }

        return (email, authPlanType ?? rateLimitsResponse?.preferredSnapshot.planType ?? "unknown")
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
