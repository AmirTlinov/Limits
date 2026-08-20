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

public enum CodexAuthBlob {
    public static func fingerprint(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func identity(from data: Data) throws -> AuthIdentity {
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CodexAuthBlobError.malformed
        }

        let authMode = object["auth_mode"] as? String
        let tokens = object["tokens"] as? [String: Any]
        let accountId = tokens?["account_id"] as? String
        let email = (tokens?["id_token"] as? String).flatMap(emailFromIDToken)

        return AuthIdentity(authMode: authMode, accountId: accountId, email: email)
    }

    private static func emailFromIDToken(_ token: String) -> String? {
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

        if let email = payload["email"] as? String, !email.isEmpty {
            return email
        }

        if let email = payload["https://api.openai.com/auth/email"] as? String, !email.isEmpty {
            return email
        }

        return nil
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
