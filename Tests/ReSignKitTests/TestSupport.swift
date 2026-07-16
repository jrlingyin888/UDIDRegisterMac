import Foundation
import Security
import UDIDRegisterKit
@testable import ReSignKit

enum TestTemp {
    static func dir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("resignkit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

/// 一次性自签名「代码签名」身份:进程内生成 RSA key,openssl 自签一张证书(DER),
/// 供 TemporaryKeychainIdentity / security cms 等集成测试复用。
struct TestSigningFixture {
    let keychainPath: String
    let commonName: String
    let privateKey: SecKey
    let certificateDER: Data
    private let cleanupPaths: [String]

    func cleanup() {
        _ = try? Subprocess.run("/usr/bin/security", ["delete-keychain", keychainPath])
        for p in cleanupPaths { try? FileManager.default.removeItem(atPath: p) }
    }

    static func make(in dir: URL) throws -> TestSigningFixture {
        let cn = "ReSignKit Test \(UUID().uuidString.prefix(8))"
        let kp = try SigningKeyPair.generateRSA2048()
        // 导出私钥为 PKCS#1 PEM 供 openssl 使用
        var err: Unmanaged<CFError>?
        guard let privDER = SecKeyCopyExternalRepresentation(kp.privateKey, &err) as Data? else {
            throw ReSignError.identityImport("导出私钥失败")
        }
        let keyPEM = dir.appendingPathComponent("key.pem")
        try pkcs1PEM(privDER).write(to: keyPEM, atomically: true, encoding: .utf8)
        // openssl 自签一张代码签名证书(DER)。必须带 codeSigning 扩展用法/密钥用法扩展,
        // 否则 `security find-identity -p codesigning` 根本不会把它当候选(而不仅仅是"不受信任")。
        let certDERURL = dir.appendingPathComponent("cert.der")
        try Subprocess.runChecked("/usr/bin/openssl", ["req", "-x509", "-new", "-key", keyPEM.path,
            "-subj", "/CN=\(cn)", "-days", "1", "-outform", "DER", "-out", certDERURL.path,
            "-addext", "keyUsage=critical,digitalSignature",
            "-addext", "extendedKeyUsage=critical,codeSigning",
            "-addext", "basicConstraints=critical,CA:false"])
        let certDER = try Data(contentsOf: certDERURL)
        // 临时钥匙串(TemporaryKeychainIdentity 内部也会建;这里给 fixture 自己一份供 cms 测试)
        let keychain = dir.appendingPathComponent("t.keychain").path
        _ = try? Subprocess.run("/usr/bin/security", ["delete-keychain", keychain])
        try Subprocess.runChecked("/usr/bin/security", ["create-keychain", "-p", "", keychain])
        try Subprocess.runChecked("/usr/bin/security", ["unlock-keychain", "-p", "", keychain])
        try Subprocess.runChecked("/usr/bin/security", ["set-keychain-settings", keychain])
        // 造 p12 导入(openssl 组装 key+cert → p12 → security import)
        // 注意:p12 导出口令**不能为空字符串**——系统 security(LibreSSL 生成的 p12)在口令为空时会
        // 报 "MAC verification failed during PKCS12 import (wrong password?)",必须用非空口令。
        let certPEM = dir.appendingPathComponent("cert.pem")
        try Subprocess.runChecked("/usr/bin/openssl", ["x509", "-inform", "DER", "-in", certDERURL.path, "-out", certPEM.path])
        let p12 = dir.appendingPathComponent("id.p12")
        let p12Password = "t\(UUID().uuidString.prefix(12))"
        try Subprocess.runChecked("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", keyPEM.path,
            "-in", certPEM.path, "-out", p12.path, "-passout", "pass:\(p12Password)", "-name", cn])
        try Subprocess.runChecked("/usr/bin/security", ["import", p12.path, "-k", keychain,
            "-P", p12Password, "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"])
        try Subprocess.runChecked("/usr/bin/security",
            ["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-k", "", keychain])
        // 特意**不**调用 `security add-trusted-cert`(见 TemporaryKeychainIdentity 里的详细说明):
        // 它需要 `com.apple.trust-settings.user` 授权,在无人值守场景下会弹窗/挂起/被系统取消。
        // codesign 无需信任即可选中自签身份;`security cms -S` 则改用 `-u 6`
        // (certUsageObjectSigner,见 ProvisioningProfileTests) 绕开默认 certUsageEmailSigner 的信任要求。
        return TestSigningFixture(keychainPath: keychain, commonName: cn,
                                  privateKey: kp.privateKey, certificateDER: certDER,
                                  cleanupPaths: [keyPEM.path, certDERURL.path, certPEM.path, p12.path])
    }

    /// 把 PKCS#1 RSAPrivateKey DER 包成 PEM
    static func pkcs1PEM(_ der: Data) -> String {
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN RSA PRIVATE KEY-----\n\(b64)\n-----END RSA PRIVATE KEY-----\n"
    }
}
