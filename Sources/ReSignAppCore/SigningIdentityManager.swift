import Foundation
import Security
import UDIDRegisterKit

public final class SigningIdentityManager {
    let store: SigningIdentityStore
    public init(store: SigningIdentityStore) { self.store = store }

    public func identity(for accountID: UUID) throws -> SigningIdentity? {
        try store.identity(for: accountID)
    }

    /// 本机生成密钥对 → 提交 CSR 建发布证书 → 组 SigningIdentity 并持久化。
    public func createAndStore(for account: AppleAccount, cred: ASCCredentials,
                               client: ASCClient) async throws -> SigningIdentity {
        let kp = try SigningKeyPair.generateRSA2048()
        let csr = try kp.makeCSR(commonName: account.displayName)
        let cert = try await client.createCertificate(credentials: cred, csrDER: csr, type: .distribution)
        let identity = SigningIdentity(privateKeyDER: try SigningKeyCodec.privateKeyDER(kp.privateKey),
                                       certificateDER: cert.contentDER, ascCertificateId: cert.id)
        try store.save(identity, for: account.id)
        return identity
    }

    /// 导入 p12：拆出私钥+证书；按证书内容在账号已注册证书里匹配 ASC id；持久化。
    public func importP12(_ data: Data, password: String, for account: AppleAccount,
                          cred: ASCCredentials, client: ASCClient) async throws -> SigningIdentity {
        var opts: [String: Any] = [kSecImportExportPassphrase as String: password]
        // 仅在内存中导入，不落地默认钥匙串：既避免污染用户登录钥匙串，也让拿到的 SecKey
        // 走新式（非 CSSM legacy）路径，才能用 SecKeyCopyExternalRepresentation 导出明文 DER。
        if #available(macOS 15.0, *) {
            opts[kSecImportToMemoryOnly as String] = true
        }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, opts as CFDictionary, &items)
        guard status == errSecSuccess,
              let arr = items as? [[String: Any]], let first = arr.first,
              let secIdentity = first[kSecImportItemIdentity as String] else {
            throw SigningIdentityError.p12Import(status)
        }
        let identityRef = secIdentity as! SecIdentity
        var privKey: SecKey?
        guard SecIdentityCopyPrivateKey(identityRef, &privKey) == errSecSuccess, let key = privKey else {
            throw SigningIdentityError.p12Import(errSecInvalidItemRef)
        }
        var certRef: SecCertificate?
        guard SecIdentityCopyCertificate(identityRef, &certRef) == errSecSuccess, let cert = certRef else {
            throw SigningIdentityError.p12Import(errSecInvalidItemRef)
        }
        let certDER = SecCertificateCopyData(cert) as Data

        // 在账号已注册证书里按内容匹配出 ASC 资源 id
        let onAccount = try await client.listCertificates(credentials: cred, type: .distribution)
        guard let match = onAccount.first(where: { $0.contentDER == certDER }) else {
            throw SigningIdentityError.certNotOnAccount
        }
        let identity = SigningIdentity(privateKeyDER: try SigningKeyCodec.privateKeyDER(key),
                                       certificateDER: certDER, ascCertificateId: match.id)
        try store.save(identity, for: account.id)
        return identity
    }
}
