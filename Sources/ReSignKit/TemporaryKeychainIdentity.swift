import Foundation
import Security

/// 把私钥+证书导入一个临时钥匙串,成为 codesign 可无弹窗使用的签名身份;用完清理。
public final class TemporaryKeychainIdentity {
    public let keychainPath: String
    public let signingIdentity: String   // 传给 codesign --sign(用 commonName)
    private let password = ""
    private var cleaned = false
    private var addedToSearchList = false

    private static let searchListLock = NSLock()

    private static func readUserKeychains() throws -> [String] {
        let r = try Subprocess.runChecked("/usr/bin/security", ["list-keychains", "-d", "user"])
        return r.stdout.split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            .filter { !$0.isEmpty }
    }
    /// 列表里是否仍有登录钥匙串——写回搜索域前必须确认,否则会把用户搜索域清空/破坏
    private static func hasLoginKeychain(_ list: [String]) -> Bool {
        list.contains { $0.contains(".keychain-db") || $0.hasSuffix("login.keychain") }
    }
    /// 是否本类创建的临时钥匙串条目(路径形如 .../resign-<uuid>/signing.keychain)
    private static func isTempEntry(_ path: String) -> Bool {
        path.hasSuffix("/signing.keychain") && path.contains("/resign-")
    }

    public init(privateKey: SecKey, certificateDER: Data, commonName: String) throws {
        self.signingIdentity = commonName
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.keychainPath = dir.appendingPathComponent("signing.keychain").path

        do {
            _ = try? Subprocess.run("/usr/bin/security", ["delete-keychain", keychainPath])
            try Subprocess.runChecked("/usr/bin/security", ["create-keychain", "-p", password, keychainPath])
            try Subprocess.runChecked("/usr/bin/security", ["unlock-keychain", "-p", password, keychainPath])
            try Subprocess.runChecked("/usr/bin/security", ["set-keychain-settings", keychainPath])

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
            // p12 导出口令不能为空(LibreSSL 生成的 p12 空口令会让 security import 报 MAC verification failed)
            let p12Password = "t\(UUID().uuidString.prefix(12))"
            try Subprocess.runChecked("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", keyPEM.path,
                "-in", certPEM.path, "-out", p12.path, "-passout", "pass:\(p12Password)", "-name", commonName])
            try Subprocess.runChecked("/usr/bin/security", ["import", p12.path, "-k", keychainPath,
                "-P", p12Password, "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"])
            // 放行 codesign 无交互使用私钥。特意不调用 add-trusted-cert(改 SecTrustSettings 会弹授权框);
            // codesign 选身份不要求系统信任,自签名证书带 codeSigning 扩展 + 私钥在钥匙串即可无弹窗签名。
            try Subprocess.runChecked("/usr/bin/security",
                ["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-k", password, keychainPath])
            // 清理明文中间产物(私钥 PEM / p12),保留钥匙串
            for u in [keyPEM, certPEM, certDERURL, p12] { try? FileManager.default.removeItem(at: u) }
        } catch {
            // init 失败时 deinit 不会被调用——必须在这里抹掉可能已落盘的私钥 PEM/p12 + 临时钥匙串
            _ = try? Subprocess.run("/usr/bin/security", ["delete-keychain", keychainPath])
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /// 把临时钥匙串并入用户搜索域,让 codesign 找得到身份。加进程锁 + 登录钥匙串守卫。
    public func addToSearchListForCodesign() throws {
        Self.searchListLock.lock(); defer { Self.searchListLock.unlock() }
        let existing = try Self.readUserKeychains()
        guard Self.hasLoginKeychain(existing) else {
            throw ReSignError.identityImport("用户钥匙串搜索域异常(未含登录钥匙串),拒绝修改")
        }
        // 自愈:剔除文件已不存在的本类临时残留(崩溃遗留),保留其它(含并发兄弟实例)条目
        let base = existing.filter { !(Self.isTempEntry($0) && !FileManager.default.fileExists(atPath: $0)) }
        addedToSearchList = true
        try Subprocess.runChecked("/usr/bin/security",
            ["list-keychains", "-d", "user", "-s"] + base + [keychainPath])
    }

    public func cleanup() {
        guard !cleaned else { return }
        cleaned = true
        if addedToSearchList {
            Self.searchListLock.lock()
            // 仅剔除“我们自己”这一条(用唯一目录名匹配,规避 /var 与 /private/var 规范化差异)
            let ourTag = URL(fileURLWithPath: keychainPath).deletingLastPathComponent().lastPathComponent
            if let existing = try? Self.readUserKeychains() {
                let remaining = existing.filter { !$0.contains(ourTag) }
                // 只有剩余列表仍含登录钥匙串才写回;否则不动搜索域,交给 delete-keychain 兜底
                if Self.hasLoginKeychain(remaining) {
                    _ = try? Subprocess.runChecked("/usr/bin/security",
                        ["list-keychains", "-d", "user", "-s"] + remaining)
                }
            }
            Self.searchListLock.unlock()
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
