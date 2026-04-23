import CryptoKit
import Foundation

enum CodexAuthBlobError: LocalizedError {
    case malformed

    var errorDescription: String? {
        switch self {
        case .malformed:
            return "The auth.json blob is malformed."
        }
    }
}

enum CodexAuthBlob {
    static func fingerprint(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func identity(from data: Data) throws -> AuthIdentity {
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CodexAuthBlobError.malformed
        }

        let authMode = object["auth_mode"] as? String
        let tokens = object["tokens"] as? [String: Any]
        let accountId = tokens?["account_id"] as? String

        return AuthIdentity(authMode: authMode, accountId: accountId)
    }
}

