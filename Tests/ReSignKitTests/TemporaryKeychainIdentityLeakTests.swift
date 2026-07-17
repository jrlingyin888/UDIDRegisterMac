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

    /// 安全不变式（优先级更高的一半）：若某证书在 import 之前就已存在于登录钥匙串
    /// （模拟用户自己的真实分发证书），TKI.cleanup() **绝不能**把它删掉。
    /// 覆盖 certPreexistedInLogin==true 分支——`cleanup` 必须跳过删除。
    func testCleanupNeverDeletesPreexistingLoginCert() throws {
        for t in ["/usr/bin/security", "/usr/bin/openssl"] {
            guard FileManager.default.isExecutableFile(atPath: t) else { throw XCTSkip("missing \(t)") }
        }
        let dir = try TestTemp.dir(); defer { try? FileManager.default.removeItem(at: dir) }

        // 生成 key + 自签「代码签名」证书（一次性、绝不可能是用户真实证书；仍用 SHA-1 精确删干净）
        let kp = try SigningKeyPair.generateRSA2048()
        var err: Unmanaged<CFError>?
        let privDER = SecKeyCopyExternalRepresentation(kp.privateKey, &err)! as Data
        let keyPEM = dir.appendingPathComponent("k.pem")
        try TestSigningFixture.pkcs1PEM(privDER).write(to: keyPEM, atomically: true, encoding: .utf8)
        let certDERURL = dir.appendingPathComponent("c.der")
        try Subprocess.runChecked("/usr/bin/openssl", ["req", "-x509", "-new", "-key", keyPEM.path,
            "-subj", "/CN=ReSign PreexistTest \(UUID().uuidString.prefix(6))", "-days", "1",
            "-outform", "DER", "-out", certDERURL.path,
            "-addext", "keyUsage=critical,digitalSignature",
            "-addext", "extendedKeyUsage=critical,codeSigning",
            "-addext", "basicConstraints=critical,CA:false"])
        let certDER = try Data(contentsOf: certDERURL)
        let sha1 = Insecure.SHA1.hash(data: certDER).map { String(format: "%02X", $0) }.joined()
        // 兜底：无论断言成败，都把这张一次性证书从登录钥匙串清干净（可能存在多份副本）
        defer {
            for _ in 0..<8 {
                let r = try? Subprocess.run("/usr/bin/security", ["delete-certificate", "-Z", sha1, "login.keychain-db"])
                if r?.status != 0 { break }
            }
        }

        // 显式把该证书预置进登录钥匙串——模拟“用户自己的真实证书本就在登录钥匙串里”。
        // 用 add-certificates（只加证书、不改信任设置，绝不触发 add-trusted-cert 的授权弹窗）。
        try Subprocess.runChecked("/usr/bin/security", ["add-certificates", "-k", "login.keychain-db", certDERURL.path])
        let seeded = try Subprocess.run("/usr/bin/security", ["find-certificate", "-a", "-Z", "login.keychain-db"])
        try XCTSkipUnless(seeded.stdout.uppercased().contains(sha1),
            "本环境无法把证书预置进登录钥匙串（add-certificates 未落地）——跳过预置不变式测试")

        // 用同一张证书构造 TKI 并 cleanup；因为 import 前它已存在 ⇒ certPreexistedInLogin 必为 true。
        let tki = try TemporaryKeychainIdentity(privateKey: kp.privateKey, certificateDER: certDER, commonName: "ReSign PreexistTest")
        tki.cleanup()

        let after = try Subprocess.run("/usr/bin/security", ["find-certificate", "-a", "-Z", "login.keychain-db"])
        XCTAssertTrue(after.stdout.uppercased().contains(sha1),
            "安全违规：cleanup 删掉了 import 前就已存在于登录钥匙串的证书（可能是用户真实证书）")
    }
}
