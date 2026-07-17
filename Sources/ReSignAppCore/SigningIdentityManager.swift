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
}
