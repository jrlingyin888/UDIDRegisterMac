import XCTest
@testable import ReSignAppCore
import ReSignKit
import UDIDRegisterKit

/// 注入式重签（C 方案）真机 PoC 门槛（injection plan 1, Task 4）。
///
/// **门槛（默认跳过）**：`POC=1` 且给了 `POC_IPA`（干净·已解密 IPA）+ `POC_PLUGIN`（插件 dylib，如 FakeGPS）
/// 才跑。签名材料**不经 env**——复用 App 已存的真实账号（`jgz_xp` 等）走**已验证的通配流程**建描述文件、
/// 取签名身份，与 `LiveAdHocReproTests.testWildcardResignM3EndToEnd` 同源，只在签名前插入注入步骤。
///
/// **落点说明**：计划字面写 `Tests/ReSignKitTests/InjectionPoCTests.swift`，但完整链路要用
/// `ASCClient`/`ReSignModel`/`KeychainSigningIdentityStore`（均在 `ReSignAppCore`，`ReSignKitTests`
/// 依赖不到），且计划 Step 1 要求「复用 ReSignModel 已验证的通配流程」——故落到 `ReSignAppCoreTests`，
/// 复用最多已验证代码、且与用户承诺提供的材料（只给 IPA + 插件）一致。
///
/// **端到端链路**：解包 IPA → `xattr -cr` → `DylibInjector.preflight`（校验已解密/arm64）
/// → `inject`（拷入 Frameworks/ + 依赖指向自带 ElleKit + insert_dylib 插 LC_LOAD_DYLIB）→ 重打包
/// → 通配描述文件 + `defaultPerformResign`（无弹窗签名）→ 产出 `~/Downloads/<name>-injected.ipa`。
/// 断言：产物存在、解包后 `codesign --verify --deep --strict` 通过、登录钥匙串证书数未净增。
///
/// **人工后续（Task 4 Step 3–4）**：把产物用 Apple Configurator 装到测试设备 → 启动 app →
/// 确认插件 hook 生效（如 FakeGPS 真改了定位）→ 记录 `.superpowers/sdd/injection-poc-result.md`。
final class InjectionPoCTests: XCTestCase {

    /// 仓库内自带的注入工具（Task 1 已提交）。运行 `swift test` 时 CWD = 包根。
    private func bundledInjectTool(_ name: String) -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/inject/\(name)")
    }

    /// 登录钥匙串里证书总数（best-effort；用于「无净增泄漏」软断言）。解析失败返回 -1。
    private func loginCertCount() -> Int {
        guard let login = try? Subprocess.runChecked("/usr/bin/security", ["login-keychain"]) else { return -1 }
        let path = login.stdout.trimmingCharacters(in: CharacterSet(charactersIn: " \"\n"))
        guard let r = try? Subprocess.run("/usr/bin/security", ["find-certificate", "-a", "-Z", path]),
              r.status == 0 else { return -1 }
        return r.stdout.components(separatedBy: "SHA-1 hash:").count - 1
    }

    @MainActor
    func testInjectionEndToEndWildcardResign() async throws {
        guard ProcessInfo.processInfo.environment["POC"] == "1" else { throw XCTSkip("set POC=1") }
        let env = ProcessInfo.processInfo.environment
        guard let ipaPath = env["POC_IPA"], let pluginPath = env["POC_PLUGIN"] else {
            throw XCTSkip("需 POC_IPA=<干净解密IPA> POC_PLUGIN=<插件dylib>")
        }
        let ipa = URL(fileURLWithPath: (ipaPath as NSString).expandingTildeInPath)
        let plugin = URL(fileURLWithPath: (pluginPath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: ipa.path) else { throw XCTSkip("POC_IPA 不存在: \(ipa.path)") }
        guard FileManager.default.fileExists(atPath: plugin.path) else { throw XCTSkip("POC_PLUGIN 不存在: \(plugin.path)") }
        let insertTool = bundledInjectTool("insert_dylib")
        let ellekit = bundledInjectTool("ElleKit.dylib")
        guard FileManager.default.isExecutableFile(atPath: insertTool.path) else { throw XCTSkip("缺自带 insert_dylib（Task 1）") }
        guard FileManager.default.fileExists(atPath: ellekit.path) else { throw XCTSkip("缺自带 ElleKit.dylib（Task 1）") }

        // 1) 真实账号 → 通配描述文件 + 签名身份（与 LIVE_RESIGN 同源）
        let store = AccountStore(fileURL: ReSignModel.liveAccountsFileURL())
        guard let acc = store.accounts.first else { throw XCTSkip("ReSignMac 账号库为空") }
        guard let pem = try KeychainSecretStore(service: ReSignAppIdentifiers.bundleID).load(for: acc.id) else { throw XCTSkip("钥匙串取不到 .p8") }
        guard let sid = try KeychainSigningIdentityStore().identity(for: acc.id) else { throw XCTSkip("无签名身份") }
        let cred = ASCCredentials(keyID: acc.keyID, issuerID: acc.issuerID, privateKeyPEM: pem)
        let client = ASCClient(http: URLSessionHTTPClient())
        let wild = try await client.findOrCreateBundleId(credentials: cred, identifier: "*", name: "ReSign Wildcard")
        let devices = try await client.listDevices(credentials: cred)
        let profile = try await client.refreshAdHocProfile(credentials: cred, name: "ReSign AdHoc Wildcard",
            bundleIdResourceId: wild.id, certificateId: sid.ascCertificateId, deviceIds: devices.map { $0.id })
        print("== 通配 App ID \(wild.id)，设备 \(devices.count) 台，描述文件 \(profile.contentData.count) 字节")

        // 2) 解包 IPA → 定位 Payload/*.app
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("poc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try Subprocess.runChecked("/usr/bin/ditto", ["-x", "-k", ipa.path, work.path])
        guard let app = IPAResigner.findPayloadApp(in: work) else { throw XCTSkip("IPA 内无 Payload/*.app") }

        // 3) 签名健壮性：清 quarantine 等扩展属性（handoff：M3 曾有 1550 文件带 quarantine xattr）
        _ = try? Subprocess.run("/usr/bin/xattr", ["-cr", app.path])

        // 4) 注入：preflight（已解密/arm64）→ inject（拷入 + 依赖指向 ElleKit + insert_dylib）
        let target = try DylibInjector.preflight(appDir: app)
        try DylibInjector.inject(plugin: plugin, into: target, insertDylibTool: insertTool, substrateReplacement: ellekit)
        let deps = try MachOInspect.dylibDependencies(target.mainExecutable)
        XCTAssertTrue(deps.contains { $0.contains(plugin.lastPathComponent) }, "主程序应加载注入的 dylib，实际：\(deps)")
        print("== 注入完成，主程序依赖含插件：\(deps.filter { $0.contains(plugin.lastPathComponent) })")

        // 5) 重打包注入后的 app → 临时 IPA
        let injectedIPA = work.appendingPathComponent("injected.ipa")
        try Subprocess.runChecked("/usr/bin/ditto",
            ["-c", "-k", "--sequesterRsrc", "--keepParent", work.appendingPathComponent("Payload").path, injectedIPA.path])

        // 6) 通配签名（无弹窗）→ 产出 ~/Downloads/<name>-injected.ipa
        let certBefore = loginCertCount()
        let out = URL(fileURLWithPath: ("~/Downloads/\(ipa.deletingPathExtension().lastPathComponent)-injected.ipa" as NSString).expandingTildeInPath)
        try? FileManager.default.removeItem(at: out)
        try ReSignModel.defaultPerformResign(ipaURL: injectedIPA, outputURL: out, identity: sid, mobileprovisionData: profile.contentData)
        let certAfter = loginCertCount()
        print("== ✅ 注入+重签产物: \(out.path) exists=\(FileManager.default.fileExists(atPath: out.path))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "应产出 injected IPA")

        // 7) 验签：解包产物 → codesign --verify --deep --strict
        let verifyDir = work.appendingPathComponent("verify")
        try FileManager.default.createDirectory(at: verifyDir, withIntermediateDirectories: true)
        try Subprocess.runChecked("/usr/bin/ditto", ["-x", "-k", out.path, verifyDir.path])
        guard let signedApp = IPAResigner.findPayloadApp(in: verifyDir) else { return XCTFail("产物内无 Payload/*.app") }
        let vr = try Subprocess.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=2", signedApp.path])
        print("== codesign --verify 退出码 \(vr.status)\n\(vr.stderr)")
        XCTAssertEqual(vr.status, 0, "注入后重签的 app 应通过 codesign --verify --deep --strict：\(vr.stderr)")

        // 8) 登录钥匙串无净增（best-effort；headless 环境可能不复现泄漏，见 progress 台账）
        if certBefore >= 0 && certAfter >= 0 {
            XCTAssertLessThanOrEqual(certAfter, certBefore, "登录钥匙串证书数不应因重签净增（before=\(certBefore) after=\(certAfter)）")
        }
    }
}
