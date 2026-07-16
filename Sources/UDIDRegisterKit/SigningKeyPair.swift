import Foundation
import Security

/// 本机 RSA-2048 密钥对:生成、导出公钥、SHA256withRSA 签名、拼 CSR。私钥不出机。
public struct SigningKeyPair {
    public let privateKey: SecKey
    public let publicKey: SecKey

    public init(privateKey: SecKey, publicKey: SecKey) {
        self.privateKey = privateKey; self.publicKey = publicKey
    }

    public static func generateRSA2048() throws -> SigningKeyPair {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ]
        var err: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &err) else {
            throw CSRError.keyGeneration
        }
        guard let pub = SecKeyCopyPublicKey(priv) else { throw CSRError.publicKeyExport }
        return SigningKeyPair(privateKey: priv, publicKey: pub)
    }

    /// PKCS#1 RSAPublicKey DER
    public func publicKeyDER() throws -> [UInt8] {
        var err: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(publicKey, &err) as Data? else {
            throw CSRError.publicKeyExport
        }
        return Array(data)
    }

    /// SHA256withRSA-PKCS1v15 签名
    public func signSHA256(_ message: [UInt8]) throws -> [UInt8] {
        var err: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(privateKey,
                .rsaSignatureMessagePKCS1v15SHA256,
                Data(message) as CFData, &err) as Data? else {
            throw CSRError.signing
        }
        return Array(sig)
    }

    public func makeCSR(commonName: String, countryCode: String = "US") throws -> Data {
        try CSRBuilder.build(commonName: commonName, countryCode: countryCode,
                             rsaPublicKeyDER: publicKeyDER(), sign: signSHA256)
    }
}
