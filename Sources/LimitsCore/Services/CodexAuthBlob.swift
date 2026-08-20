import CryptoKit
import Foundation
import LimitsShared

public enum CodexAuthBlobError: LocalizedError {
    case malformed

    public var errorDescription: String? {
        switch self {
        case .malformed:
            return L10n.tr("codex.auth.malformed")
        }
    }
}

public struct CodexAuthMetadata: Sendable {
    public let identity: AuthIdentity
    public let planType: String?
    public let subscriptionPeriod: ChatGPTSubscriptionPeriod?

    public init(
        identity: AuthIdentity,
        planType: String?,
        subscriptionPeriod: ChatGPTSubscriptionPeriod?
    ) {
        self.identity = identity
        self.planType = planType
        self.subscriptionPeriod = subscriptionPeriod
    }
}

public enum CodexAuthBlob {
    public static func fingerprint(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func identity(from data: Data) throws -> AuthIdentity {
        try metadata(from: data).identity
    }

    public static func metadata(from data: Data) throws -> CodexAuthMetadata {
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CodexAuthBlobError.malformed
        }

        let authMode = object["auth_mode"] as? String
        let tokens = object["tokens"] as? [String: Any]
        let accountId = tokens?["account_id"] as? String
        let idTokenPayload = (tokens?["id_token"] as? String).flatMap(jwtPayload)
        let email = email(from: idTokenPayload)
        let authClaims = idTokenPayload?["https://api.openai.com/auth"] as? [String: Any]
        let planType = nonEmptyString(authClaims?["chatgpt_plan_type"])
        let subscriptionPeriod = subscriptionPeriod(from: authClaims)

        return CodexAuthMetadata(
            identity: AuthIdentity(authMode: authMode, accountId: accountId, email: email),
            planType: planType,
            subscriptionPeriod: subscriptionPeriod
        )
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else {
            return nil
        }

        guard
            let payloadData = base64URLDecode(String(parts[1])),
            let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            return nil
        }

        return payload
    }

    private static func email(from payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        if let email = payload["email"] as? String, !email.isEmpty {
            return email
        }

        if let email = payload["https://api.openai.com/auth/email"] as? String, !email.isEmpty {
            return email
        }

        return nil
    }

    private static func subscriptionPeriod(from authClaims: [String: Any]?) -> ChatGPTSubscriptionPeriod? {
        guard let authClaims else { return nil }
        let activeStart = parseISO8601(nonEmptyString(authClaims["chatgpt_subscription_active_start"]))
        let activeUntil = parseISO8601(nonEmptyString(authClaims["chatgpt_subscription_active_until"]))
        let lastCheckedAt = parseISO8601(nonEmptyString(authClaims["chatgpt_subscription_last_checked"]))
        guard activeStart != nil || activeUntil != nil || lastCheckedAt != nil else { return nil }
        return ChatGPTSubscriptionPeriod(
            activeStart: activeStart,
            activeUntil: activeUntil,
            lastCheckedAt: lastCheckedAt
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseISO8601(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = base64.count % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: 4 - padding))
        }

        return Data(base64Encoded: base64)
    }
}
