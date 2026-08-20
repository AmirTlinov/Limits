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

struct JSONRPCServerError: Error, Decodable, LocalizedError {
    let code: Int?
    let message: String

    var errorDescription: String? { message }
}

