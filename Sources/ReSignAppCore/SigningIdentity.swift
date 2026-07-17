import Foundation
import Security

public struct SigningIdentity: Equatable {
    public let privateKeyDER: Data
    public let certificateDER: Data
    public let ascCertificateId: String
    public init(privateKeyDER: Data, certificateDER: Data, ascCertificateId: String) {
        self.privateKeyDER = privateKeyDER; self.certificateDER = certificateDER
        self.ascCertificateId = ascCertificateId
    }
}

public enum SigningIdentityError: Error, LocalizedError {
    case keychain(OSStatus)
    case badKeyData
    case p12Import(OSStatus)
    case certNotOnAccount
    public var errorDescription: String? {
        switch self {
        case .keychain(let s): return "钥匙串错误(\(s))"
        case .badKeyData: return "私钥数据无法解析"
        case .p12Import(let s): return "p12 导入失败(\(s))，检查密码或格式"
        case .certNotOnAccount: return "该 p12 的证书未在此账号注册，无法用于构建描述文件"
        }
    }
}

/// RSA 私钥 DER <-> SecKey
public enum SigningKeyCodec {
    public static func privateKeyDER(_ key: SecKey) throws -> Data {
        var err: Unmanaged<CFError>?
        guard let d = SecKeyCopyExternalRepresentation(key, &err) as Data? else { throw SigningIdentityError.badKeyData }
        return d
    }
    public static func makeRSAPrivateKey(fromDER der: Data) throws -> SecKey {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &err) else {
            throw SigningIdentityError.badKeyData
        }
        return key
    }
}
