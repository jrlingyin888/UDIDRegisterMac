import Foundation
import Observation
import AppKit
import UDIDRegisterKit
import ReSignKit

public enum IdentityStatus: Equatable { case notCreated; case ready }

public enum ReSignAppError: LocalizedError {
    case msg(String)
    public var errorDescription: String? { if case let .msg(m) = self { return m }; return nil }
}

@MainActor
@Observable
public final class ReSignModel {
    public var accounts: [AppleAccount] = []
    public var selectedID: UUID?
    public var log: [String] = []
    public var busy = false
    public var banner: String?
    public var selectedIPA: URL?
    public var selectedPlugin: URL?

    public var readBundleID: (URL) throws -> String = { try IPAResigner.readBundleIdentifier(ipaURL: $0) }
    public var performResign: (_ ipaURL: URL, _ outputURL: URL, _ identity: SigningIdentity, _ mobileprovisionData: Data) throws -> Void
        = ReSignModel.defaultPerformResign
    /// 注意：签名后会删除返回 URL 的父目录，故自定义实现必须返回一个「自己独占的全新临时目录内」的 URL
    /// （切勿返回入参 `ipaURL`，也勿指向含其他文件的目录）。
    public var performInjection: (_ ipaURL: URL, _ plugin: URL) throws -> URL
        = ReSignModel.defaultPerformInjection
    public var revealInFinder: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    let store: AccountStore
    let secrets: SecretStore
    let identity: SigningIdentityManager
    let client: ASCClient

    public init(store: AccountStore, secrets: SecretStore,
                identity: SigningIdentityManager, client: ASCClient) {
        self.store = store; self.secrets = secrets; self.identity = identity; self.client = client
        reload()
    }

    public func reload() {
        accounts = store.accounts
        if selectedID == nil || !accounts.contains(where: { $0.id == selectedID }) {
            selectedID = accounts.first?.id
        }
    }
    public var selected: AppleAccount? { accounts.first { $0.id == selectedID } }

    public func identityStatus(for accountID: UUID) -> IdentityStatus {
        ((try? identity.identity(for: accountID)) ?? nil) == nil ? .notCreated : .ready
    }

    func credentials(for a: AppleAccount) throws -> ASCCredentials {
        guard let pem = try secrets.load(for: a.id) else { throw ReSignAppError.msg("找不到该账号的 .p8，请重新导入账号") }
        return ASCCredentials(keyID: a.keyID, issuerID: a.issuerID, privateKeyPEM: pem)
    }

    /// 复用注册助手导出的 AccountConfig：解析 → 联网校验 → 存账号 + .p8。
    public func importAccountConfig(from url: URL) async -> Bool {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { banner = "读取配置文件失败：\(UserFacingMessage.from(error))"; return false }
        let config: AccountConfig
        do { config = try AccountConfigCodec.decode(data) }
        catch { banner = UserFacingMessage.from(error); return false }
        let account = AppleAccount(displayName: config.displayName, keyID: config.keyID,
                                   issuerID: config.issuerID, teamID: config.teamID)
        let cred = ASCCredentials(keyID: config.keyID, issuerID: config.issuerID, privateKeyPEM: config.p8PEM)
        do { _ = try await client.listDevices(credentials: cred) }
        catch { banner = "凭据校验失败：\(UserFacingMessage.from(error))"; return false }
        do { try secrets.save(config.p8PEM, for: account.id); try store.add(account) }
        catch { try? secrets.delete(for: account.id); banner = "保存失败：\(UserFacingMessage.from(error))"; return false }
        reload(); selectedID = account.id; banner = nil
        return true
    }

    public func deleteAccount(id: UUID) {
        try? secrets.delete(for: id)
        try? identity.store.remove(for: id)
        try? store.remove(id: id)
        reload()
    }

    /// 给当前账号自动创建并持久化签名身份（app 自建证书）。
    public func createIdentity() async -> Bool {
        guard let a = selected else { banner = "请先选择账号"; return false }
        busy = true; defer { busy = false }
        do {
            _ = try await identity.createAndStore(for: a, cred: try credentials(for: a), client: client)
            banner = nil; return true
        } catch { banner = UserFacingMessage.from(error); return false }
    }

    /// 给当前账号导入 p12 作为签名身份。
    public func importP12(from url: URL, password: String) async -> Bool {
        guard let a = selected else { banner = "请先选择账号"; return false }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        busy = true; defer { busy = false }
        do {
            let data = try Data(contentsOf: url)
            _ = try await identity.importP12(data, password: password, for: a, cred: try credentials(for: a), client: client)
            banner = nil; return true
        } catch { banner = UserFacingMessage.from(error); return false }
    }

    /// 把当前账号的签名身份导出为 p12 写到用户选的位置。口令不能为空。
    public func exportP12(to url: URL, password: String) -> Bool {
        guard let a = selected else { banner = "请先选择账号"; return false }
        guard !password.isEmpty else { banner = "请为导出的 p12 设置一个非空密码"; return false }
        do {
            let data = try identity.exportP12(for: a.id, password: password)
            try data.write(to: url, options: .atomic)
            banner = nil; return true
        } catch { banner = UserFacingMessage.from(error); return false }
    }

    /// 一键重签：读 bundleId → 确保 App ID → 全部设备 → 刷描述文件 → 重签 → Finder 显示。
    public func resign() async {
        banner = nil; log = []
        guard let a = selected else { banner = "请先选择账号"; return }
        guard let ipa = selectedIPA else { banner = "请先选择 IPA"; return }
        guard let sid = (try? identity.identity(for: a.id)) ?? nil else {
            banner = "该账号还没有签名身份，请先「自动创建」或「导入 p12」"; return
        }
        busy = true; defer { busy = false }
        do {
            let cred = try credentials(for: a)
            let built = try await buildAdHocProfile(ipa: ipa, cred: cred, sid: sid)
            let output = ReSignModel.resolveOutputURL(for: ipa, injected: selectedPlugin != nil)
            if output.deletingLastPathComponent() != ipa.deletingLastPathComponent() {
                log.append("源目录只读，已改输出到下载文件夹")
            }
            if let plugin = selectedPlugin { log.append("注入 \(plugin.lastPathComponent)…") }
            log.append("重签中…")
            let work = performResign
            let inject = performInjection
            let plugin = selectedPlugin
            let mobileprovisionData = built.profileData
            try await Task.detached {
                let toSign = try plugin.map { try inject(ipa, $0) } ?? ipa
                defer {
                    if plugin != nil {
                        let parent = toSign.deletingLastPathComponent()
                        let tempRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
                        // 仅删我们自己的临时注入目录（系统临时目录下）；绝不误删用户源目录
                        if parent.resolvingSymlinksInPath().path.hasPrefix(tempRoot) {
                            try? FileManager.default.removeItem(at: parent)
                        }
                    }
                }
                try work(toSign, output, sid, mobileprovisionData)
            }.value
            log.append("✅ 完成：\(output.lastPathComponent)")
            revealInFinder(output)
        } catch {
            banner = UserFacingMessage.from(error)
            log.append("❌ 失败：\(banner ?? "")")
        }
    }

    /// 产出 IPA 的落点：默认与源同目录 `<原名>-resigned.ipa`；源目录不可写（如挂载只读 DMG）时退回 ~/Downloads。
    public static func resolveOutputURL(
        for source: URL,
        injected: Bool = false,
        isDirWritable: (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) },
        downloadsDir: () -> URL = {
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        }
    ) -> URL {
        let name = source.deletingPathExtension().lastPathComponent + (injected ? "-injected.ipa" : "-resigned.ipa")
        let srcDir = source.deletingLastPathComponent()
        if isDirWritable(srcDir.path) { return srcDir.appendingPathComponent(name) }
        return downloadsDir().appendingPathComponent(name)
    }

    /// 生成「当前账号 + 选中 IPA 的 bundle id」对应的最新 Ad Hoc 描述文件（含账号下全部设备）。
    /// resign() 与 exportProfile() 共用，避免重复；每步 append 到 log。
    private func buildAdHocProfile(ipa: URL, cred: ASCCredentials,
                                   sid: SigningIdentity) async throws -> (bundleID: String, profileData: Data) {
        log.append("读取 IPA 的 bundle id…")
        let bundleID = try readBundleID(ipa)
        log.append("bundle id：\(bundleID)")
        log.append("确认 App ID…")
        let appID = try await resolveBundleIdForAdHoc(cred: cred, bundleID: bundleID)
        let data = try await refreshProfile(cred: cred, sid: sid, appID: appID)
        return (bundleID, data)
    }

    /// 建「通配 App ID（*）+ 全部设备」的 Ad Hoc 描述文件——不依赖具体 IPA，对任意 bundle id 通用。
    /// 供无 IPA 的导出使用（第三方 app 的显式 App ID 必被占用，导出的本就是这份通配）。
    private func buildWildcardProfile(cred: ASCCredentials, sid: SigningIdentity) async throws -> Data {
        log.append("确认通配 App ID（*）…")
        let wild = try await client.findOrCreateBundleId(credentials: cred, identifier: "*", name: "ReSign Wildcard")
        return try await refreshProfile(cred: cred, sid: sid, appID: (wild.id, "ReSign AdHoc Wildcard"))
    }

    /// 用给定 App ID（resourceId + profileName）+ 账号下**全部设备**刷 Ad Hoc 描述文件，返回描述文件字节。
    private func refreshProfile(cred: ASCCredentials, sid: SigningIdentity,
                               appID: (resourceId: String, profileName: String)) async throws -> Data {
        log.append("获取账号下全部设备…")
        let devices = try await client.listDevices(credentials: cred)
        log.append("设备 \(devices.count) 台，刷新 Ad Hoc 描述文件…")
        let profile = try await client.refreshAdHocProfile(
            credentials: cred, name: appID.profileName,
            bundleIdResourceId: appID.resourceId, certificateId: sid.ascCertificateId,
            deviceIds: devices.map { $0.id })
        return profile.contentData
    }

    /// 优先建/用与 bundle id 匹配的**显式** App ID；被原开发者占用（Apple 409 "not available"）时
    /// 回退到**通配** App ID（`*`）——通配 Ad Hoc 描述文件对任意 bundle id 都适用，是重签第三方 app 的通用做法。
    private func resolveBundleIdForAdHoc(cred: ASCCredentials, bundleID: String)
        async throws -> (resourceId: String, profileName: String) {
        do {
            let b = try await client.findOrCreateBundleId(credentials: cred, identifier: bundleID, name: bundleID)
            return (b.id, "ReSign AdHoc \(bundleID)")
        } catch ASCError.http(409, _) {
            log.append("该 bundle id 已被原开发者占用，改用通配 App ID（*）")
            let wild = try await client.findOrCreateBundleId(credentials: cred, identifier: "*", name: "ReSign Wildcard")
            return (wild.id, "ReSign AdHoc Wildcard")
        }
    }

    /// 导出「含当前全部设备」的 Ad Hoc 描述文件（.mobileprovision），供配 p12 在别处重签。
    /// **选了 IPA** → 按其 bundle id 生成（显式优先、409 回退通配）；**没选 IPA** → 直接导出**通配**描述文件
    /// （对任意 app 通用）。是一次**快照**——之后再加设备需重新导出。
    public func exportProfile(to url: URL) async -> Bool {
        banner = nil; log = []
        guard let a = selected else { banner = "请先选择账号"; return false }
        guard let sid = (try? identity.identity(for: a.id)) ?? nil else {
            banner = "该账号还没有签名身份，请先「自动创建」或「导入 p12」"; return false
        }
        busy = true; defer { busy = false }
        do {
            let cred = try credentials(for: a)
            let profileData: Data
            if let ipa = selectedIPA {
                profileData = try await buildAdHocProfile(ipa: ipa, cred: cred, sid: sid).profileData
            } else {
                log.append("未选 IPA，导出通配描述文件（对任意 app 通用）")
                profileData = try await buildWildcardProfile(cred: cred, sid: sid)
            }
            try profileData.write(to: url, options: .atomic)
            log.append("✅ 描述文件已导出：\(url.lastPathComponent)")
            return true
        } catch {
            banner = UserFacingMessage.from(error)
            log.append("❌ 失败：\(banner ?? "")")
            return false
        }
    }

    /// 默认重签：还原私钥 → 组临时钥匙串身份 → IPAResigner。
    public static func defaultPerformResign(ipaURL: URL, outputURL: URL,
                                            identity sid: SigningIdentity, mobileprovisionData: Data) throws {
        let key = try SigningKeyCodec.makeRSAPrivateKey(fromDER: sid.privateKeyDER)
        let tki = try TemporaryKeychainIdentity(privateKey: key, certificateDER: sid.certificateDER, commonName: "ReSign")
        defer { tki.cleanup() }
        try tki.addToSearchListForCodesign()
        try IPAResigner.resign(ipaURL: ipaURL, outputURL: outputURL, identity: tki, mobileprovisionData: mobileprovisionData)
    }

    /// 默认注入：解包 IPA → 定位 app → xattr -cr → preflight（已解密/arm64）→ inject（内置 insert_dylib + ElleKit）
    /// → 重打包为临时 IPA，返回其 URL。失败时清掉自己的临时目录。
    public static func defaultPerformInjection(ipaURL: URL, plugin: URL) throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("inject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            try Subprocess.runChecked("/usr/bin/ditto", ["-x", "-k", ipaURL.path, work.path])
            guard let app = IPAResigner.findPayloadApp(in: work) else { throw ReSignAppError.msg("IPA 内找不到 Payload/*.app") }
            _ = try? Subprocess.run("/usr/bin/xattr", ["-cr", app.path])
            let target = try DylibInjector.preflight(appDir: app)
            try DylibInjector.inject(plugin: plugin, into: target,
                                     insertDylibTool: try BundledInjectTools.insertDylib,
                                     substrateReplacement: try BundledInjectTools.ellekit)
            let injectedIPA = work.appendingPathComponent("injected.ipa")
            try Subprocess.runChecked("/usr/bin/ditto",
                ["-c", "-k", "--sequesterRsrc", "--keepParent", work.appendingPathComponent("Payload").path, injectedIPA.path])
            return injectedIPA
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }
}
