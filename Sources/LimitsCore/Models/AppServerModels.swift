import Foundation

struct AppServerInitializeResponse: Decodable {
    let userAgent: String
    let codexHome: String
    let platformFamily: String
    let platformOs: String
}

struct AppServerAccountPayload: Decodable {
    let type: String
    let email: String?
    let planType: String?
}

struct AppServerGetAccountResponse: Decodable {
    let account: AppServerAccountPayload?
    let requiresOpenaiAuth: Bool
}

struct AppServerLoginResponse: Decodable {
    let type: String
    let loginId: String?
    let authUrl: String?
    let verificationUrl: String?
    let userCode: String?
}

struct AppServerCancelLoginResponse: Decodable {
    let status: String
}

struct AppServerLoginCompletedNotification: Decodable {
    let success: Bool
    let error: String?
    let loginId: String?
}

struct AppServerRateLimitsResponse: Decodable {
    let rateLimits: RateLimitSnapshotModel
    let rateLimitsByLimitId: [String: RateLimitSnapshotModel]?

    var preferredSnapshot: RateLimitSnapshotModel {
        if let codex = rateLimitsByLimitId?["codex"] {
            return codex
        }
        return rateLimits
    }
}

struct AppServerAccountUsageResponse: Decodable {
    let summary: Summary
    let dailyUsageBuckets: [DailyBucket]?
    let threadUsage: ThreadUsage?

    struct Summary: Decodable {
        let lifetimeTokens: Int64?
        let peakDailyTokens: Int64?
        let longestRunningTurnSec: Int64?
        let currentStreakDays: Int64?
        let longestStreakDays: Int64?
    }

    struct DailyBucket: Decodable {
        let startDate: String
        let tokens: Int64
    }

    struct ThreadUsage: Decodable {
        let threadId: String
        let estimatedUsageCreditsMicros: Int64
        let estimatedUsageUsdMicros: Int64?
        let groups: [Group]

        struct Group: Decodable {
            let model: String?
            let reasoningEffort: String?
            let speed: String?
            let inputTokens: Int64?
            let cachedInputTokens: Int64?
            let netNewInputTokens: Int64?
            let outputTokens: Int64?
            let totalTokens: Int64?
            let estimatedUsageCreditsMicros: Int64
        }
    }
}

struct JSONRPCServerError: Error, Decodable, LocalizedError {
    let code: Int?
    let message: String

    var errorDescription: String? { message }
}

