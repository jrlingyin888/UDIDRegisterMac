import Foundation
import Security
import CryptoKit

/// 把私钥+证书导入一个临时钥匙串,成为 codesign 可无弹窗使用的签名身份;用完清理。
public final class TemporaryKeychainIdentity {
    public let keychainPath: String
    public let signingIdentity: String   // 传给 codesign --sign(叶证书 SHA-1 指纹,40 位大写十六进制——唯一且不与 ASC display name / CN 混淆)
    private let password = ""
    private var cleaned = false
    private var addedToSearchList = false

    private static let searchListLock = NSLock()

    /// 叶证书 DER 的 SHA-1 指纹,40 位大写十六进制——codesign --sign 的规范无歧义选择器
    /// (ASC display name ≠ X.509 CN,CN 还可能与用户真实登录证书撞名)。
    static func sha1Hex(_ der: Data) -> String {
        Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }

    private static func readUserKeychains() throws -> [String] {
        let r = try Subprocess.runChecked("/usr/bin/security", ["list-keychains", "-d", "user"])
        return r.stdout.split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            .filter { !$0.isEmpty }
    }
    /// 解析真实登录钥匙串的绝对路径。优先 `-d user`;某些无 GUI/Aqua 会话的沙盒环境下
    /// 该域解析会失败(空输出、退出码 1),这时退化为不带 -d 的默认解析(仍返回同一登录钥匙串)。
    private static func resolveLoginKeychainPath() throws -> String {
        let r: Subprocess.Result
        if let byUserDomain = try? Subprocess.runChecked("/usr/bin/security", ["login-keychain", "-d", "user"]) {
            r = byUserDomain
        } else {
            r = try Subprocess.runChecked("/usr/bin/security", ["login-keychain"])
        }
        return r.stdout.trimmingCharacters(in: CharacterSet(charactersIn: " \"\n"))
    }
    /// 列表里是否仍有登录钥匙串——写回搜索域前必须确认,否则会把用户搜索域清空/破坏。
    /// 用精确路径匹配(而非 ".keychain-db" 子串),因为子串同样会命中临时钥匙串。
    private static func hasLoginKeychain(_ list: [String]) -> Bool {
        guard let login = try? resolveLoginKeychainPath(), !login.isEmpty else { return false }
        return list.contains(login)
    }
    /// 是否本类创建的临时钥匙串条目(路径形如 .../resign-<uuid>/signing.keychain[-db])。
    /// 用 contains 而非 hasSuffix 匹配 "signing.keychain",因为 macOS 有时会给钥匙串文件加 "-db" 后缀。
    private static func isTempEntry(_ path: String) -> Bool {
        path.contains("/resign-") && path.contains("signing.keychain")
    }

    public init(privateKey: SecKey, certificateDER: Data, commonName: String) throws {
        self.signingIdentity = TemporaryKeychainIdentity.sha1Hex(certificateDER)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        self.keychainPath = dir.appendingPathComponent("signing.keychain").path

        var keyPEM: URL?
        var certPEM: URL?
        var p12: URL?
        do {
            _ = try? Subprocess.run("/usr/bin/security", ["delete-keychain", keychainPath])
            try Subprocess.runChecked("/usr/bin/security", ["create-keychain", "-p", password, keychainPath])
            try Subprocess.runChecked("/usr/bin/security", ["unlock-keychain", "-p", password, keychainPath])
            try Subprocess.runChecked("/usr/bin/security", ["set-keychain-settings", keychainPath])

            var err: Unmanaged<CFError>?
            guard let privDER = SecKeyCopyExternalRepresentation(privateKey, &err) as Data? else {
                throw ReSignError.identityImport("导出私钥失败")
            }
            let keyPEMURL = dir.appendingPathComponent("k.pem"); keyPEM = keyPEMURL
            try TemporaryKeychainIdentity.pkcs1PEM(privDER).write(to: keyPEMURL, atomically: true, encoding: .utf8)
            let certDERURL = dir.appendingPathComponent("c.der"); try certificateDER.write(to: certDERURL)
            let certPEMURL = dir.appendingPathComponent("c.pem"); certPEM = certPEMURL
            try Subprocess.runChecked("/usr/bin/openssl", ["x509", "-inform", "DER", "-in", certDERURL.path, "-out", certPEMURL.path])
            let p12URL = dir.appendingPathComponent("id.p12"); p12 = p12URL
            // p12 导出口令不能为空(LibreSSL 生成的 p12 空口令会让 security import 报 MAC verification failed)
            let p12Password = "t\(UUID().uuidString.prefix(12))"
            try Subprocess.runChecked("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", keyPEMURL.path,
                "-in", certPEMURL.path, "-out", p12URL.path, "-passout", "pass:\(p12Password)", "-name", commonName])
            try Subprocess.runChecked("/usr/bin/security", ["import", p12URL.path, "-k", keychainPath,
                "-P", p12Password, "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"])
            // 放行 codesign 无交互使用私钥。特意不调用 add-trusted-cert(改 SecTrustSettings 会弹授权框);
            // codesign 选身份不要求系统信任,自签名证书带 codeSigning 扩展 + 私钥在钥匙串即可无弹窗签名。
            try Subprocess.runChecked("/usr/bin/security",
                ["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-k", password, keychainPath])
            // 清理明文中间产物(私钥 PEM / p12),保留钥匙串。先原地清零再删除,缩短明文私钥落盘窗口。
            // 更彻底的方案是全程不落盘、直接 SecItemAdd 导入内存中的 key+cert——留作后续优化。
            for u in [certDERURL, keyPEMURL, certPEMURL, p12URL] { TemporaryKeychainIdentity.shred(u) }
        } catch {
            // init 失败时 deinit 不会被调用——必须在这里抹掉可能已落盘的私钥 PEM/p12 + 临时钥匙串
            for u in [keyPEM, certPEM, p12].compactMap({ $0 }) { TemporaryKeychainIdentity.shred(u) }
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

    /// 尽力抹掉磁盘上的明文文件内容(用等长的零字节覆盖)再删除,缩短私钥/p12 明文落盘的可被读取窗口。
    /// 这是尽力而为(best-effort):不保证对抗 SSD 磨损均衡/日志式文件系统的底层拷贝语义,
    /// 完整方案是全程不落盘、直接内存态 SecItemAdd 导入(见 init 中注释),留作后续优化。
    private static func shred(_ url: URL) {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > 0 {
            try? Data(count: size).write(to: url)
        }
        try? FileManager.default.removeItem(at: url)
    }
}
