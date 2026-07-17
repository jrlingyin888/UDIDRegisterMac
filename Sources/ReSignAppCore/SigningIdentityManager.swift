import Foundation
import Security
import UDIDRegisterKit
import ReSignKit

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

    /// 导入 p12：用 openssl 从 p12 抽出私钥(PKCS#1 DER)+证书(DER)，**不碰 Security import、不碰钥匙串**；
    /// 按证书内容在账号已注册证书里匹配 ASC id；持久化。
    public func importP12(_ data: Data, password: String, for account: AppleAccount,
                          cred: ASCCredentials, client: ASCClient) async throws -> SigningIdentity {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("p12-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let p12 = dir.appendingPathComponent("in.p12"); try data.write(to: p12)
        let keyPEM = dir.appendingPathComponent("k.pem"), certPEM = dir.appendingPathComponent("c.pem")
        let keyDERURL = dir.appendingPathComponent("k.der"), certDERURL = dir.appendingPathComponent("c.der")
        do {
            let pwIn = Data((password + "\n").utf8)
            // 私钥（-nodes 未加密 PEM，-nocerts 只要 key）；密码走 stdin，不进 argv（避免 ps 泄露）
            try Subprocess.runChecked("/usr/bin/openssl", ["pkcs12", "-in", p12.path,
                "-passin", "stdin", "-nocerts", "-nodes", "-out", keyPEM.path], input: pwIn)
            // 叶子证书
            try Subprocess.runChecked("/usr/bin/openssl", ["pkcs12", "-in", p12.path,
                "-passin", "stdin", "-clcerts", "-nokeys", "-out", certPEM.path], input: pwIn)
            // 转 DER：私钥用 PKCS#1 RSAPrivateKey DER（与 SecKeyCopyExternalRepresentation 一致），证书用 DER
            try Subprocess.runChecked("/usr/bin/openssl", ["rsa", "-in", keyPEM.path, "-outform", "DER", "-out", keyDERURL.path])
            try Subprocess.runChecked("/usr/bin/openssl", ["x509", "-in", certPEM.path, "-outform", "DER", "-out", certDERURL.path])
        } catch {
            throw SigningIdentityError.p12Import(errSecAuthFailed)   // 密码错误或 p12 格式无法解析
        }
        let privateKeyDER = try Data(contentsOf: keyDERURL)
        let certificateDER = try Data(contentsOf: certDERURL)
        // 抹掉明文中间产物（defer 会删目录，这里再覆写一遍私钥文件降低残留窗口）
        for u in [keyPEM, keyDERURL] { try? Data(count: (try? Data(contentsOf: u))?.count ?? 0).write(to: u) }

        // 在账号已注册证书里按内容匹配出 ASC 资源 id
        let onAccount = try await client.listCertificates(credentials: cred, type: .distribution)
        guard let match = onAccount.first(where: { $0.contentDER == certificateDER }) else {
            throw SigningIdentityError.certNotOnAccount
        }
        let identity = SigningIdentity(privateKeyDER: privateKeyDER,
                                       certificateDER: certificateDER, ascCertificateId: match.id)
        try store.save(identity, for: account.id)
        return identity
    }

    /// 从持久化的 SigningIdentity 组回 .p12：openssl 把 PKCS#1 私钥 DER + 证书 DER 拼成 p12。
    /// 导出口令走 stdin，不进 argv；明文中间产物用完抹除。
    public func exportP12(for accountID: UUID, password: String) throws -> Data {
        guard let id = try store.identity(for: accountID) else { throw SigningIdentityError.badKeyData }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("p12out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyDER = dir.appendingPathComponent("k.der"), keyPEM = dir.appendingPathComponent("k.pem")
        let certDER = dir.appendingPathComponent("c.der"), certPEM = dir.appendingPathComponent("c.pem")
        let out = dir.appendingPathComponent("out.p12")
        // 抹掉明文私钥中间产物；LIFO 下此 defer 后注册、先执行（在删目录之前），成功/失败都跑。
        defer {
            for u in [keyPEM, keyDER] {
                if let n = (try? Data(contentsOf: u))?.count, n > 0 { try? Data(count: n).write(to: u) }
            }
        }
        try id.privateKeyDER.write(to: keyDER)
        try id.certificateDER.write(to: certDER)
        do {
            try Subprocess.runChecked("/usr/bin/openssl", ["rsa", "-inform", "DER", "-in", keyDER.path, "-out", keyPEM.path])
            try Subprocess.runChecked("/usr/bin/openssl", ["x509", "-inform", "DER", "-in", certDER.path, "-out", certPEM.path])
            try Subprocess.runChecked("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", keyPEM.path,
                "-in", certPEM.path, "-out", out.path, "-passout", "stdin", "-name", "ReSign Distribution"],
                input: Data((password + "\n").utf8))
        } catch {
            throw SigningIdentityError.p12Import(errSecIO)
        }
        return try Data(contentsOf: out)
    }
}
