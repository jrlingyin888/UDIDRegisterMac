import Foundation
import Security

/// 把私钥+证书导入一个临时钥匙串,成为 codesign 可无弹窗使用的签名身份;用完清理。
public final class TemporaryKeychainIdentity {
    public let keychainPath: String
    public let signingIdentity: String   // 传给 codesign --sign(用 commonName)
    private let password = ""
    private var cleaned = false
    private var addedToSearchList = false

    public init(privateKey: SecKey, certificateDER: Data, commonName: String) throws {
        self.signingIdentity = commonName
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.keychainPath = dir.appendingPathComponent("signing.keychain").path

        _ = try? Subprocess.run("/usr/bin/security", ["delete-keychain", keychainPath])
        try Subprocess.runChecked("/usr/bin/security", ["create-keychain", "-p", password, keychainPath])
        try Subprocess.runChecked("/usr/bin/security", ["unlock-keychain", "-p", password, keychainPath])
        // 允许后续 set-key-partition-list 无提示操作此钥匙串(默认锁定超时可能触发交互)
        try Subprocess.runChecked("/usr/bin/security", ["set-keychain-settings", keychainPath])

        // 组装 p12(openssl)再 import——比 SecItemAdd 跨版本更稳
        var err: Unmanaged<CFError>?
        guard let privDER = SecKeyCopyExternalRepresentation(privateKey, &err) as Data? else {
            throw ReSignError.identityImport("导出私钥失败")
        }
        let keyPEM = dir.appendingPathComponent("k.pem")
        try TemporaryKeychainIdentity.pkcs1PEM(privDER).write(to: keyPEM, atomically: true, encoding: .utf8)
        let certDERURL = dir.appendingPathComponent("c.der"); try certificateDER.write(to: certDERURL)
        let certPEM = dir.appendingPathComponent("c.pem")
        try Subprocess.runChecked("/usr/bin/openssl", ["x509", "-inform", "DER", "-in", certDERURL.path, "-out", certPEM.path])
        let p12 = dir.appendingPathComponent("id.p12")
        // 注意:p12 导出口令**不能为空字符串**——系统 security(LibreSSL 生成的 p12)在口令为空时会
        // 报 "MAC verification failed during PKCS12 import (wrong password?)",必须用非空口令。
        let p12Password = "t\(UUID().uuidString.prefix(12))"
        try Subprocess.runChecked("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", keyPEM.path,
            "-in", certPEM.path, "-out", p12.path, "-passout", "pass:\(p12Password)", "-name", commonName])
        try Subprocess.runChecked("/usr/bin/security", ["import", p12.path, "-k", keychainPath,
            "-P", p12Password, "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"])
        // 放行 codesign 无交互使用私钥
        try Subprocess.runChecked("/usr/bin/security",
            ["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-k", password, keychainPath])
        // 特意**不**调用 `security add-trusted-cert`:它改的是 SecTrustSettings,受
        // `com.apple.trust-settings.user` 授权项保护,首次(或授权缓存过期后)会弹出图形化
        // 授权对话框,在无人值守场景下会挂起/被系统取消(实测报错
        // "SecTrustSettingsSetTrustSettings: The authorization was canceled by the user.")。
        // 经验证:codesign 选择签名身份并不要求该身份被系统信任——自签名证书只要带有
        // codeSigning 扩展用法(keyUsage/extendedKeyUsage/basicConstraints,由调用方证书提供)
        // 且私钥在 keychain 内可用,`codesign --sign <commonName>` 与 `--verify` 均可无弹窗通过,
        // 即便 `security find-identity` 把它标注为 CSSMERR_TP_NOT_TRUSTED。
        // 清理明文中间产物(p12/pem),保留钥匙串
        for u in [keyPEM, certPEM, certDERURL, p12] { try? FileManager.default.removeItem(at: u) }
    }

    /// 把临时钥匙串并入搜索域,让 codesign 找得到身份
    public func addToSearchListForCodesign() throws {
        let list = try Subprocess.run("/usr/bin/security", ["list-keychains", "-d", "user"])
        let existing = list.stdout.split(separator: "\n").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        }
        addedToSearchList = true
        try Subprocess.runChecked("/usr/bin/security",
            ["list-keychains", "-d", "user", "-s"] + existing + [keychainPath])
    }

    public func cleanup() {
        guard !cleaned else { return }
        cleaned = true
        if addedToSearchList {
            let list = try? Subprocess.run("/usr/bin/security", ["list-keychains", "-d", "user"])
            let existing = (list?.stdout.split(separator: "\n").map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            } ?? []).filter { $0 != keychainPath }
            _ = try? Subprocess.run("/usr/bin/security",
                ["list-keychains", "-d", "user", "-s"] + existing)
        }
        _ = try? Subprocess.run("/usr/bin/security", ["delete-keychain", keychainPath])
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: keychainPath).deletingLastPathComponent())
    }
    deinit { cleanup() }

    static func pkcs1PEM(_ der: Data) -> String {
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN RSA PRIVATE KEY-----\n\(b64)\n-----END RSA PRIVATE KEY-----\n"
    }
}
