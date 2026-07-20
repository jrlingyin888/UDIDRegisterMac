import XCTest
@testable import ReSignAppCore
import UDIDRegisterKit

/// 临时真实-API 探针（LIVE_REPRO=1 才跑）。用 ReSignApp 已存的真实账号复现
/// 「显式 App ID 不可用」并探通配 App ID 方案。调查完删除。
final class LiveAdHocReproTests: XCTestCase {
    @MainActor
    func testProbeRealAccountAppIDAndWildcard() async throws {
        guard ProcessInfo.processInfo.environment["LIVE_REPRO"] == "1" else { throw XCTSkip("set LIVE_REPRO=1") }
        let store = AccountStore(fileURL: ReSignModel.liveAccountsFileURL())
        guard let acc = store.accounts.first else { throw XCTSkip("ReSignMac 账号库为空") }
        let secrets = KeychainSecretStore(service: ReSignAppIdentifiers.bundleID)
        guard let pem = try secrets.load(for: acc.id) else { throw XCTSkip("钥匙串取不到 .p8（ACL?）") }
        print("\n== 账号 \(acc.displayName) key=\(acc.keyID) issuer=\(acc.issuerID)")
        let cred = ASCCredentials(keyID: acc.keyID, issuerID: acc.issuerID, privateKeyPEM: pem)
        let client = ASCClient(http: URLSessionHTTPClient())
        let bid = "com.seeyon.m3.appstore.new.phone"

        // 1) 账号下是否已有该显式 App ID
        let matches = try await client.listBundleIds(credentials: cred, identifier: bid)
        print("== 显式 \(bid) 已存在: \(matches.map { "\($0.identifier)#\($0.id)" })")

        // 2) 试建显式 App ID → 预期 'not available'
        do { let b = try await client.createBundleId(credentials: cred, identifier: bid, name: bid)
             print("== 显式建成功(意外): \(b.id)") }
        catch { print("== 显式建失败(预期): \(error)") }

        // 3) 探通配 '*'：账号是否已有 / 能否建
        let wild = try await client.listBundleIds(credentials: cred, identifier: "*")
        print("== 通配 '*' 已存在: \(wild.map { "\($0.identifier)#\($0.id)" })")
        if wild.isEmpty {
            do { let w = try await client.createBundleId(credentials: cred, identifier: "*", name: "ReSign Wildcard")
                 print("== 通配 '*' 建成功: \(w.id) \(w.identifier)") }
            catch { print("== 通配 '*' 建失败: \(error)") }
        }
    }

    /// 直接把「通配 Ad Hoc 描述文件（含全部设备）」导出到 ~/Downloads（EXPORT_PROFILE=1 才跑）。
    @MainActor
    func testExportWildcardProfileToDownloads() async throws {
        guard ProcessInfo.processInfo.environment["EXPORT_PROFILE"] == "1" else { throw XCTSkip("set EXPORT_PROFILE=1") }
        let store = AccountStore(fileURL: ReSignModel.liveAccountsFileURL())
        guard let acc = store.accounts.first else { throw XCTSkip("no account") }
        guard let pem = try KeychainSecretStore(service: ReSignAppIdentifiers.bundleID).load(for: acc.id) else { throw XCTSkip("no p8") }
        guard let sid = try KeychainSigningIdentityStore().identity(for: acc.id) else { throw XCTSkip("no signing identity") }
        let cred = ASCCredentials(keyID: acc.keyID, issuerID: acc.issuerID, privateKeyPEM: pem)
        let client = ASCClient(http: URLSessionHTTPClient())
        let wild = try await client.findOrCreateBundleId(credentials: cred, identifier: "*", name: "ReSign Wildcard")
        let devices = try await client.listDevices(credentials: cred)
        let profile = try await client.refreshAdHocProfile(credentials: cred, name: "ReSign AdHoc Wildcard",
            bundleIdResourceId: wild.id, certificateId: sid.ascCertificateId, deviceIds: devices.map { $0.id })
        let out = URL(fileURLWithPath: ("~/Downloads/ReSign-AdHoc-Wildcard.mobileprovision" as NSString).expandingTildeInPath)
        try? FileManager.default.removeItem(at: out)
        try profile.contentData.write(to: out)
        print("== ✅ 描述文件已导出: \(out.path) (\(profile.contentData.count) 字节, 通配 App ID \(wild.id), \(devices.count) 台设备, 证书 \(sid.ascCertificateId))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
    }

    /// 集成真实验证：跑 ReSignModel.live() 的完整 exportProfile 路径（经通配回退）（LIVE_INTEGRATED=1 才跑）。
    @MainActor
    func testLiveIntegratedExportProfileUsesWildcardFallback() async throws {
        guard ProcessInfo.processInfo.environment["LIVE_INTEGRATED"] == "1" else { throw XCTSkip("set LIVE_INTEGRATED=1") }
        let m = ReSignModel.live()
        guard let first = m.accounts.first else { throw XCTSkip("no account") }
        m.selectedID = first.id
        let ipa = URL(fileURLWithPath: ("~/Downloads/M3_v4.7.5_84303.ipa" as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: ipa.path) else { throw XCTSkip("no M3 ipa") }
        m.selectedIPA = ipa
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("verify-\(UUID().uuidString).mobileprovision")
        let ok = await m.exportProfile(to: out)
        print("== integrated exportProfile ok=\(ok) banner=\(m.banner ?? "nil")")
        print("== log:\n" + m.log.joined(separator: "\n"))
        try? FileManager.default.removeItem(at: out)
        XCTAssertTrue(ok, "集成路径应成功(经通配回退): \(m.banner ?? "")")
    }

    /// 端到端：用通配 App ID 建 Ad Hoc 描述文件，真实重签 M3（LIVE_RESIGN=1 才跑）。
    @MainActor
    func testWildcardResignM3EndToEnd() async throws {
        guard ProcessInfo.processInfo.environment["LIVE_RESIGN"] == "1" else { throw XCTSkip("set LIVE_RESIGN=1") }
        let store = AccountStore(fileURL: ReSignModel.liveAccountsFileURL())
        guard let acc = store.accounts.first else { throw XCTSkip("no account") }
        guard let pem = try KeychainSecretStore(service: ReSignAppIdentifiers.bundleID).load(for: acc.id) else { throw XCTSkip("no p8") }
        guard let sid = try KeychainSigningIdentityStore().identity(for: acc.id) else { throw XCTSkip("no signing identity") }
        let ipa = URL(fileURLWithPath: (("~/Downloads/M3_v4.7.5_84303.ipa") as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: ipa.path) else { throw XCTSkip("no M3 ipa") }

        let cred = ASCCredentials(keyID: acc.keyID, issuerID: acc.issuerID, privateKeyPEM: pem)
        let client = ASCClient(http: URLSessionHTTPClient())

        let wild = try await client.findOrCreateBundleId(credentials: cred, identifier: "*", name: "ReSign Wildcard")
        print("== 通配 App ID: \(wild.id) \(wild.identifier)")
        let devices = try await client.listDevices(credentials: cred)
        print("== 设备 \(devices.count) 台")
        let profile = try await client.refreshAdHocProfile(credentials: cred, name: "ReSign AdHoc Wildcard",
            bundleIdResourceId: wild.id, certificateId: sid.ascCertificateId, deviceIds: devices.map { $0.id })
        print("== 描述文件 \(profile.contentData.count) 字节")

        let out = ipa.deletingPathExtension().appendingPathExtension("resigned.ipa")
        try? FileManager.default.removeItem(at: out)
        do {
            try ReSignModel.defaultPerformResign(ipaURL: ipa, outputURL: out, identity: sid, mobileprovisionData: profile.contentData)
            print("== ✅ 重签成功: \(out.path) exists=\(FileManager.default.fileExists(atPath: out.path)) size=\((try? FileManager.default.attributesOfItem(atPath: out.path)[.size]) ?? 0)")
        } catch {
            print("== ❌ 重签失败: \(error)")
            throw error
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
    }
}
