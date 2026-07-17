import XCTest
@testable import ReSignAppCore
import UDIDRegisterKit
import ReSignKit
import Security

final class SigningIdentityManagerTests: XCTestCase {
    let account = AppleAccount(displayName: "Acme", keyID: "K", issuerID: "I", teamID: "T")
    let cred = ASCCredentials(keyID: "K", issuerID: "I", privateKeyPEM: "PEM")
    func client(_ h: @escaping (String, String) -> HTTPResponse) -> ASCClient {
        ASCClient(http: MockHTTP(h), signJWT: { _ in "T" })
    }

    func testCreateAndStorePersistsCertIdAndUsableKey() async throws {
        let certDER = Data([0x30, 0x01, 0x00])
        let c = client { method, path in
            // createCertificate POST /v1/certificates
            MockHTTP.json(201, ["data": ["id": "CERT9",
                "attributes": ["name": "Dist", "certificateContent": certDER.base64EncodedString()]]])
        }
        let store = InMemorySigningIdentityStore()
        let mgr = SigningIdentityManager(store: store)
        let identity = try await mgr.createAndStore(for: account, cred: cred, client: c)
        XCTAssertEqual(identity.ascCertificateId, "CERT9")
        XCTAssertEqual(identity.certificateDER, certDER)
        XCTAssertFalse(identity.privateKeyDER.isEmpty)
        // 已持久化
        XCTAssertEqual(try store.identity(for: account.id), identity)
        // 私钥可还原并签名
        let key = try SigningKeyCodec.makeRSAPrivateKey(fromDER: identity.privateKeyDER)
        var err: Unmanaged<CFError>?
        XCTAssertNotNil(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data("x".utf8) as CFData, &err))
    }

    /// 用测试现造的 p12（openssl）导入：私钥+证书拆出、且按证书内容在账号上匹配到 ASC id
    func testImportP12MatchesAccountCertAndStores() async throws {
        for t in ["/usr/bin/openssl"] { guard FileManager.default.isExecutableFile(atPath: t) else { throw XCTSkip("no \(t)") } }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // 造 key + 自签名证书 + p12（口令非空）
        let (p12Data, certDER) = try Self.makeTestP12(in: tmp, password: "pw")
        // 账号上「已注册」的证书列表里含这张（按 certificateContent 匹配）
        let c = client { method, _ in
            MockHTTP.json(200, ["data": [["id": "CERTX",
                "attributes": ["certificateContent": certDER.base64EncodedString()]]]])
        }
        let store = InMemorySigningIdentityStore()
        let mgr = SigningIdentityManager(store: store)
        let identity = try await mgr.importP12(p12Data, password: "pw", for: account, cred: cred, client: c)
        XCTAssertEqual(identity.ascCertificateId, "CERTX")
        XCTAssertEqual(identity.certificateDER, certDER)
        XCTAssertFalse(identity.privateKeyDER.isEmpty)
        XCTAssertEqual(try store.identity(for: account.id), identity)
        // 私钥可还原并签名（证明 openssl 产出的 DER 与 SecKeyCreateWithData 兼容）
        let key = try SigningKeyCodec.makeRSAPrivateKey(fromDER: identity.privateKeyDER)
        var err: Unmanaged<CFError>?
        XCTAssertNotNil(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data("x".utf8) as CFData, &err))
    }

    func testImportP12FailsWhenCertNotOnAccount() async throws {
        for t in ["/usr/bin/openssl"] { guard FileManager.default.isExecutableFile(atPath: t) else { throw XCTSkip("no \(t)") } }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (p12Data, _) = try Self.makeTestP12(in: tmp, password: "pw")
        let c = client { _, _ in MockHTTP.json(200, ["data": []]) }   // 账号上没有任何证书
        let mgr = SigningIdentityManager(store: InMemorySigningIdentityStore())
        do { _ = try await mgr.importP12(p12Data, password: "pw", for: account, cred: cred, client: c); XCTFail("应抛错") }
        catch SigningIdentityError.certNotOnAccount {} // ok
    }

    /// 存一套身份 → exportP12 → 用同密码 openssl 解回，证书内容一致、私钥可用
    func testExportP12RoundTrips() async throws {
        for t in ["/usr/bin/openssl"] { guard FileManager.default.isExecutableFile(atPath: t) else { throw XCTSkip("no \(t)") } }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 造 key(PKCS#1 DER) + 自签证书(DER)，一致成对
        let keyPEM = tmp.appendingPathComponent("k.pem"), keyDER = tmp.appendingPathComponent("k.der")
        let certPEM = tmp.appendingPathComponent("c.pem"), certDER = tmp.appendingPathComponent("c.der")
        func ossl(_ a: [String]) throws { _ = try Subprocess.runChecked("/usr/bin/openssl", a) }
        try ossl(["genrsa", "-out", keyPEM.path, "2048"])
        try ossl(["rsa", "-in", keyPEM.path, "-outform", "DER", "-out", keyDER.path])
        try ossl(["req", "-x509", "-new", "-key", keyPEM.path, "-subj", "/CN=ReSign Export Test", "-days", "1", "-out", certPEM.path])
        try ossl(["x509", "-in", certPEM.path, "-outform", "DER", "-out", certDER.path])
        let privDER = try Data(contentsOf: keyDER), cDER = try Data(contentsOf: certDER)

        let store = InMemorySigningIdentityStore()
        let mgr = SigningIdentityManager(store: store)
        let accID = UUID()
        try store.save(SigningIdentity(privateKeyDER: privDER, certificateDER: cDER, ascCertificateId: "C"), for: accID)

        let p12 = try mgr.exportP12(for: accID, password: "pw")
        XCTAssertFalse(p12.isEmpty)

        // 用同密码解回证书，断言与原证书一致
        let p12URL = tmp.appendingPathComponent("out.p12"); try p12.write(to: p12URL)
        let back = tmp.appendingPathComponent("back.pem")
        _ = try Subprocess.runChecked("/usr/bin/openssl", ["pkcs12", "-in", p12URL.path,
            "-passin", "stdin", "-nokeys", "-clcerts", "-out", back.path], input: Data("pw\n".utf8))
        let backDER = tmp.appendingPathComponent("back.der")
        _ = try Subprocess.runChecked("/usr/bin/openssl", ["x509", "-in", back.path, "-outform", "DER", "-out", backDER.path])
        XCTAssertEqual(try Data(contentsOf: backDER), cDER)
    }

    /// 现造一张自签名代码签名证书 + p12，返回 (p12Data, certDER)
    static func makeTestP12(in dir: URL, password: String) throws -> (Data, Data) {
        func sh(_ args: [String]) throws { _ = try Subprocess.runChecked("/usr/bin/openssl", args) }
        let key = dir.appendingPathComponent("k.pem"), certPEM = dir.appendingPathComponent("c.pem")
        let certDERURL = dir.appendingPathComponent("c.der"), p12 = dir.appendingPathComponent("id.p12")
        try sh(["genrsa", "-out", key.path, "2048"])
        try sh(["req", "-x509", "-new", "-key", key.path, "-subj", "/CN=ReSign Test", "-days", "1", "-out", certPEM.path])
        try sh(["x509", "-in", certPEM.path, "-outform", "DER", "-out", certDERURL.path])
        try sh(["pkcs12", "-export", "-inkey", key.path, "-in", certPEM.path, "-out", p12.path,
                "-passout", "pass:\(password)", "-name", "ReSign Test"])
        return (try Data(contentsOf: p12), try Data(contentsOf: certDERURL))
    }
}
