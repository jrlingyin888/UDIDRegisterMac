import XCTest
import Security
import CryptoKit
import UDIDRegisterKit
@testable import ReSignKit

final class TemporaryKeychainIdentityLeakTests: XCTestCase {
    /// TKI 用完后，登录钥匙串不得残留它导入时新增的证书副本。
    func testCleanupRemovesLeakedCertFromLoginKeychain() throws {
        for t in ["/usr/bin/security", "/usr/bin/openssl"] {
            guard FileManager.default.isExecutableFile(atPath: t) else { throw XCTSkip("missing \(t)") }
        }
        let dir = try TestTemp.dir(); defer { try? FileManager.default.removeItem(at: dir) }

        // 生成 key + 自签「代码签名」证书（不经任何 keychain import，避免污染前置状态）
        let kp = try SigningKeyPair.generateRSA2048()
        var err: Unmanaged<CFError>?
        let privDER = SecKeyCopyExternalRepresentation(kp.privateKey, &err)! as Data
        let keyPEM = dir.appendingPathComponent("k.pem")
        try TestSigningFixture.pkcs1PEM(privDER).write(to: keyPEM, atomically: true, encoding: .utf8)
        let certDERURL = dir.appendingPathComponent("c.der")
        try Subprocess.runChecked("/usr/bin/openssl", ["req", "-x509", "-new", "-key", keyPEM.path,
            "-subj", "/CN=ReSign LeakTest \(UUID().uuidString.prefix(6))", "-days", "1",
            "-outform", "DER", "-out", certDERURL.path,
            "-addext", "keyUsage=critical,digitalSignature",
            "-addext", "extendedKeyUsage=critical,codeSigning",
            "-addext", "basicConstraints=critical,CA:false"])
        let certDER = try Data(contentsOf: certDERURL)
        let sha1 = Insecure.SHA1.hash(data: certDER).map { String(format: "%02X", $0) }.joined()
        // 兜底：断言失败也别把证书留在登录钥匙串
        defer {
            for _ in 0..<8 {
                let r = try? Subprocess.run("/usr/bin/security", ["delete-certificate", "-Z", sha1, "login.keychain-db"])
                if r?.status != 0 { break }
            }
        }

        // 前提：登录钥匙串本来没有这张一次性证书
        let before = try Subprocess.run("/usr/bin/security", ["find-certificate", "-a", "-Z", "login.keychain-db"])
        XCTAssertFalse(before.stdout.uppercased().contains(sha1), "测试前提被破坏：登录钥匙串已含该证书")

        let tki = try TemporaryKeychainIdentity(privateKey: kp.privateKey, certificateDER: certDER, commonName: "ReSign LeakTest")
        tki.cleanup()

        let after = try Subprocess.run("/usr/bin/security", ["find-certificate", "-a", "-Z", "login.keychain-db"])
        XCTAssertFalse(after.stdout.uppercased().contains(sha1), "泄漏未修复：TKI 的证书副本仍在登录钥匙串")
    }
}
