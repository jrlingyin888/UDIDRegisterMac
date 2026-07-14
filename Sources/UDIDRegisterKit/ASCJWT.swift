import Foundation
import CryptoKit

public enum ASCJWTError: Error, LocalizedError {
    case invalidPrivateKey
    public var errorDescription: String? {
        "这个 .p8 文件无法识别，请确认是从 App Store Connect 下载的原始 .p8 文件"
    }
}

public enum ASCJWT {
    public static func sign(keyID: String, issuerID: String,
                            privateKeyPEM: String, now: Date = Date()) throws -> String {
        let key: P256.Signing.PrivateKey
        do { key = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM) }
        catch { throw ASCJWTError.invalidPrivateKey }

        let t = Int(now.timeIntervalSince1970)
        let header: [String: Any] = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
        let payload: [String: Any] = ["iss": issuerID, "iat": t - 30,
                                      "exp": t + 1100, "aud": "appstoreconnect-v1"]
        let signingInput = try b64(header) + "." + b64(payload)
        let sig = try key.signature(for: Data(signingInput.utf8))
        return signingInput + "." + base64URL(sig.rawRepresentation)
    }

    static func b64(_ obj: [String: Any]) throws -> String {
        base64URL(try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]))
    }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
