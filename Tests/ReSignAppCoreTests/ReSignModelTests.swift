import XCTest
@testable import ReSignAppCore
import UDIDRegisterKit
import ReSignKit

@MainActor
final class ReSignModelTests: XCTestCase {
    func makeModel(client: ASCClient) throws -> (ReSignModel, InMemorySigningIdentityStore) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("acc-\(UUID().uuidString).json")
        let idStore = InMemorySigningIdentityStore()
        let m = ReSignModel(store: AccountStore(fileURL: tmp),
                            secrets: InMemorySecretStore(),
                            identity: SigningIdentityManager(store: idStore),
                            client: client)
        return (m, idStore)
    }

    func testResolveOutputURLUsesSourceDirWhenWritable() {
        let src = URL(fileURLWithPath: "/tmp/demo.ipa")
        let out = ReSignModel.resolveOutputURL(for: src, isDirWritable: { _ in true },
                                               downloadsDir: { URL(fileURLWithPath: "/Users/x/Downloads") })
        XCTAssertEqual(out, URL(fileURLWithPath: "/tmp/demo-resigned.ipa"))
    }

    func testResolveOutputURLFallsBackToDownloadsWhenReadOnly() {
        let src = URL(fileURLWithPath: "/Volumes/DMG/demo.ipa")
        let out = ReSignModel.resolveOutputURL(for: src, isDirWritable: { _ in false },
                                               downloadsDir: { URL(fileURLWithPath: "/Users/x/Downloads") })
        XCTAssertEqual(out, URL(fileURLWithPath: "/Users/x/Downloads/demo-resigned.ipa"))
    }

    func testIdentityStatusReflectsStore() throws {
        let (m, idStore) = try makeModel(client: ASCClient(http: MockHTTP { _, _ in MockHTTP.json(200, ["data": []]) }, signJWT: { _ in "T" }))
        let acc = AppleAccount(displayName: "A", keyID: "K", issuerID: "I")
        XCTAssertEqual(m.identityStatus(for: acc.id), .notCreated)
        try idStore.save(SigningIdentity(privateKeyDER: Data([1]), certificateDER: Data([2]), ascCertificateId: "C"), for: acc.id)
        XCTAssertEqual(m.identityStatus(for: acc.id), .ready)
    }

    func testResignPipelineOrderAndDeviceIds() async throws {
        // client: findOrCreateBundleId(GET 空→POST 建)、listDevices 两台、createAdHocProfile 返回 profile
        let profileData = Data([0xAB, 0xCD])
        let mock = MockHTTP { method, path in
            if path.hasSuffix("v1/bundleIds") { // GET 空 → POST 建
                return method == "GET" ? MockHTTP.json(200, ["data": []])
                    : MockHTTP.json(201, ["data": ["id": "B1", "attributes": ["identifier": "com.demo.app", "name": "com.demo.app"]]])
            }
            if path.hasSuffix("v1/devices") {
                return MockHTTP.json(200, ["data": [
                    ["id": "D1", "attributes": ["udid": "u1", "name": "d1", "status": "ENABLED"]],
                    ["id": "D2", "attributes": ["udid": "u2", "name": "d2", "status": "ENABLED"]]]])
            }
            if path.hasSuffix("v1/profiles") { // 无同名删除(GET 空) → POST 建
                return method == "GET" ? MockHTTP.json(200, ["data": []])
                    : MockHTTP.json(201, ["data": ["id": "P1", "attributes": ["name": "n", "profileContent": profileData.base64EncodedString()]]])
            }
            return MockHTTP.json(200, ["data": []])
        }
        let c = ASCClient(http: mock, signJWT: { _ in "T" })

        let (m, idStore) = try makeModel(client: c)
        // 装一个账号 + 一套身份
        let acc = AppleAccount(displayName: "A", keyID: "K", issuerID: "I")
        try m.store.add(acc); try m.secrets.save("PEM", for: acc.id); m.reload(); m.selectedID = acc.id
        try idStore.save(SigningIdentity(privateKeyDER: Data([1]), certificateDER: Data([2]), ascCertificateId: "CERT1"), for: acc.id)

        // 注入假的 readBundleID / performResign（不碰真实 codesign）
        m.readBundleID = { _ in "com.demo.app" }
        var captured: (URL, URL, SigningIdentity, Data)?
        m.performResign = { ipa, out, id, mp in captured = (ipa, out, id, mp) }
        m.revealInFinder = { _ in }     // 避免测试弹 Finder
        m.selectedIPA = URL(fileURLWithPath: "/tmp/demo.ipa")

        await m.resign()

        XCTAssertNil(m.banner, "不应有错误：\(m.banner ?? "")")
        let cap = try XCTUnwrap(captured)
        XCTAssertEqual(cap.1, URL(fileURLWithPath: "/tmp/demo-resigned.ipa"))  // 输出同目录 -resigned
        XCTAssertEqual(cap.2.ascCertificateId, "CERT1")
        XCTAssertEqual(cap.3, profileData)                                     // profile 内容透传

        // 断言描述文件请求确实带上了账号下的全部设备
        let profilePost = mock.requests.last { $0.method == "POST" && $0.url.path.hasSuffix("v1/profiles") }
        let body = try XCTUnwrap(profilePost?.body)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let rel = ((json["data"] as! [String: Any])["relationships"]) as! [String: Any]
        let devs = ((rel["devices"] as! [String: Any])["data"]) as! [[String: Any]]
        XCTAssertEqual(Set(devs.compactMap { $0["id"] as? String }), ["D1", "D2"])
    }

    func testResignRefusesWhenNoIdentity() async throws {
        let c = ASCClient(http: MockHTTP { _, _ in MockHTTP.json(200, ["data": []]) }, signJWT: { _ in "T" })
        let (m, _) = try makeModel(client: c)
        let acc = AppleAccount(displayName: "A", keyID: "K", issuerID: "I")
        try m.store.add(acc); try m.secrets.save("PEM", for: acc.id); m.reload(); m.selectedID = acc.id
        m.selectedIPA = URL(fileURLWithPath: "/tmp/demo.ipa")
        m.readBundleID = { _ in "com.demo.app" }
        await m.resign()
        XCTAssertNotNil(m.banner)  // 无签名身份 → 报错中止
    }

    func testResignSurfacesUnsupportedNestedBundle() async throws {
        let profileData = Data([0x01])
        let c = ASCClient(http: MockHTTP { method, path in
            if path.hasSuffix("v1/bundleIds") { return MockHTTP.json(201, ["data": ["id": "B", "attributes": ["identifier": "x", "name": "x"]]]) }
            if path.hasSuffix("v1/devices") { return MockHTTP.json(200, ["data": []]) }
            if path.hasSuffix("v1/profiles") { return method == "GET" ? MockHTTP.json(200, ["data": []]) : MockHTTP.json(201, ["data": ["id": "P", "attributes": ["profileContent": profileData.base64EncodedString()]]]) }
            return MockHTTP.json(200, ["data": []])
        }, signJWT: { _ in "T" })
        let (m, idStore) = try makeModel(client: c)
        let acc = AppleAccount(displayName: "A", keyID: "K", issuerID: "I")
        try m.store.add(acc); try m.secrets.save("PEM", for: acc.id); m.reload(); m.selectedID = acc.id
        try idStore.save(SigningIdentity(privateKeyDER: Data([1]), certificateDER: Data([2]), ascCertificateId: "C"), for: acc.id)
        m.selectedIPA = URL(fileURLWithPath: "/tmp/demo.ipa")
        m.readBundleID = { _ in "com.demo.app" }
        m.performResign = { _, _, _, _ in throw ReSignError.unsupportedNestedBundle(["Ext.appex"]) }
        await m.resign()
        XCTAssertNotNil(m.banner)
        XCTAssertTrue(m.banner!.contains("扩展") || m.banner!.contains("Ext.appex"))
    }

    func testExportP12RejectsEmptyPassword() throws {
        let c = ASCClient(http: MockHTTP { _, _ in MockHTTP.json(200, ["data": []]) }, signJWT: { _ in "T" })
        let (m, idStore) = try makeModel(client: c)
        let acc = AppleAccount(displayName: "A", keyID: "K", issuerID: "I")
        try m.store.add(acc); try m.secrets.save("PEM", for: acc.id); m.reload(); m.selectedID = acc.id
        try idStore.save(SigningIdentity(privateKeyDER: Data([1]), certificateDER: Data([2]), ascCertificateId: "C"), for: acc.id)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).p12")
        let ok = m.exportP12(to: out, password: "")
        XCTAssertFalse(ok)                       // 空口令被拒
        XCTAssertNotNil(m.banner)                // 且有提示 banner
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))  // 未落盘
    }

    func testCreateIdentityStoresAndSetsReady() async throws {
        let certDER = Data([0x30, 0x01, 0x00])
        let c = ASCClient(http: MockHTTP { _, _ in
            MockHTTP.json(201, ["data": ["id": "CERT7",
                "attributes": ["name": "Dist", "certificateContent": certDER.base64EncodedString()]]])
        }, signJWT: { _ in "T" })
        let (m, idStore) = try makeModel(client: c)
        let acc = AppleAccount(displayName: "A", keyID: "K", issuerID: "I")
        try m.store.add(acc); try m.secrets.save("PEM", for: acc.id); m.reload(); m.selectedID = acc.id

        let ok = await m.createIdentity()

        XCTAssertTrue(ok)
        XCTAssertNil(m.banner, "不应有错误：\(m.banner ?? "")")
        XCTAssertEqual(m.identityStatus(for: acc.id), .ready)
        let stored = try idStore.identity(for: acc.id)
        XCTAssertEqual(stored?.ascCertificateId, "CERT7")
        XCTAssertEqual(stored?.certificateDER, certDER)
    }

    func testLiveAccountsFileURLIsResignScopedAndSeparateFromRegisterApp() {
        let url = ReSignModel.liveAccountsFileURL()
        XCTAssertEqual(url.lastPathComponent, "accounts.json")
        XCTAssertTrue(url.deletingLastPathComponent().lastPathComponent == "ReSignMac",
                      "ReSignApp 账号库必须独立目录，实际：\(url.path)")
        XCTAssertFalse(url.path.contains("/UDIDRegisterMac/"), "不得与注册 app 共用账号文件")
    }

    func testExportProfileWritesAllDeviceProfile() async throws {
        let profileData = Data([0xAB, 0xCD])
        let mock = MockHTTP { method, path in
            if path.hasSuffix("v1/bundleIds") {
                return method == "GET" ? MockHTTP.json(200, ["data": []])
                    : MockHTTP.json(201, ["data": ["id": "B1", "attributes": ["identifier": "com.demo.app", "name": "com.demo.app"]]])
            }
            if path.hasSuffix("v1/devices") {
                return MockHTTP.json(200, ["data": [
                    ["id": "D1", "attributes": ["udid": "u1", "name": "d1", "status": "ENABLED"]],
                    ["id": "D2", "attributes": ["udid": "u2", "name": "d2", "status": "ENABLED"]]]])
            }
            if path.hasSuffix("v1/profiles") {
                return method == "GET" ? MockHTTP.json(200, ["data": []])
                    : MockHTTP.json(201, ["data": ["id": "P1", "attributes": ["name": "n", "profileContent": profileData.base64EncodedString()]]])
            }
            return MockHTTP.json(200, ["data": []])
        }
        let c = ASCClient(http: mock, signJWT: { _ in "T" })
        let (m, idStore) = try makeModel(client: c)
        let acc = AppleAccount(displayName: "A", keyID: "K", issuerID: "I")
        try m.store.add(acc); try m.secrets.save("PEM", for: acc.id); m.reload(); m.selectedID = acc.id
        try idStore.save(SigningIdentity(privateKeyDER: Data([1]), certificateDER: Data([2]), ascCertificateId: "CERT1"), for: acc.id)
        m.readBundleID = { _ in "com.demo.app" }
        m.selectedIPA = URL(fileURLWithPath: "/tmp/demo.ipa")

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("prof-\(UUID().uuidString).mobileprovision")
        defer { try? FileManager.default.removeItem(at: out) }

        let ok = await m.exportProfile(to: out)

        XCTAssertTrue(ok)
        XCTAssertNil(m.banner, "不应有错误：\(m.banner ?? "")")
        XCTAssertEqual(try Data(contentsOf: out), profileData)   // 写出的正是描述文件内容

        // 断言描述文件请求带上了账号下全部设备（新加的 UDID 会自动纳入这份导出）
        let profilePost = mock.requests.last { $0.method == "POST" && $0.url.path.hasSuffix("v1/profiles") }
        let body = try XCTUnwrap(profilePost?.body)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let rel = ((json["data"] as! [String: Any])["relationships"]) as! [String: Any]
        let devs = ((rel["devices"] as! [String: Any])["data"]) as! [[String: Any]]
        XCTAssertEqual(Set(devs.compactMap { $0["id"] as? String }), ["D1", "D2"])
    }

    func testExportProfileRefusesWithoutIPA() async throws {
        let c = ASCClient(http: MockHTTP { _, _ in MockHTTP.json(200, ["data": []]) }, signJWT: { _ in "T" })
        let (m, idStore) = try makeModel(client: c)
        let acc = AppleAccount(displayName: "A", keyID: "K", issuerID: "I")
        try m.store.add(acc); try m.secrets.save("PEM", for: acc.id); m.reload(); m.selectedID = acc.id
        try idStore.save(SigningIdentity(privateKeyDER: Data([1]), certificateDER: Data([2]), ascCertificateId: "C"), for: acc.id)
        // 未选 IPA → 无法确定 bundle id → 拒绝、不落盘
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).mobileprovision")
        let ok = await m.exportProfile(to: out)
        XCTAssertFalse(ok)
        XCTAssertNotNil(m.banner)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    /// 第三方 app 的 bundle id 被原开发者占用（显式 App ID 建返回 409 not available）→ 自动回退通配 '*'。
    func testResignFallsBackToWildcardWhenAppIdNotAvailable() async throws {
        final class Box: @unchecked Sendable {
            private let lock = NSLock(); private var n = 0
            func nextBundlePost() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        }
        let box = Box()
        let profileData = Data([0xEE, 0xFF])
        let mock = MockHTTP { method, path in
            if path.hasSuffix("v1/bundleIds") {
                if method == "GET" { return MockHTTP.json(200, ["data": []]) }   // 显式/通配 GET 都空
                // 第 1 个 POST（显式）→ 409 not available；第 2 个 POST（通配）→ 201
                return box.nextBundlePost() == 1
                    ? MockHTTP.json(409, ["errors": [["detail": "An App ID with Identifier 'com.demo.app' is not available. Please enter a different string."]]])
                    : MockHTTP.json(201, ["data": ["id": "WILD", "attributes": ["identifier": "*", "name": "ReSign Wildcard"]]])
            }
            if path.hasSuffix("v1/devices") {
                return MockHTTP.json(200, ["data": [["id": "D1", "attributes": ["udid": "u1", "name": "d1", "status": "ENABLED"]]]])
            }
            if path.hasSuffix("v1/profiles") {
                return method == "GET" ? MockHTTP.json(200, ["data": []])
                    : MockHTTP.json(201, ["data": ["id": "P", "attributes": ["profileContent": profileData.base64EncodedString()]]])
            }
            return MockHTTP.json(200, ["data": []])
        }
        let c = ASCClient(http: mock, signJWT: { _ in "T" })
        let (m, idStore) = try makeModel(client: c)
        let acc = AppleAccount(displayName: "A", keyID: "K", issuerID: "I")
        try m.store.add(acc); try m.secrets.save("PEM", for: acc.id); m.reload(); m.selectedID = acc.id
        try idStore.save(SigningIdentity(privateKeyDER: Data([1]), certificateDER: Data([2]), ascCertificateId: "C"), for: acc.id)
        m.readBundleID = { _ in "com.demo.app" }
        var captured: Data?
        m.performResign = { _, _, _, mp in captured = mp }
        m.revealInFinder = { _ in }
        m.selectedIPA = URL(fileURLWithPath: "/tmp/demo.ipa")

        await m.resign()

        XCTAssertNil(m.banner, "应回退到通配、不报错：\(m.banner ?? "")")
        XCTAssertEqual(captured, profileData)
        // 先显式后通配：两次 bundleIds POST
        let bundlePosts = mock.requests.filter { $0.method == "POST" && $0.url.path.hasSuffix("v1/bundleIds") }
        XCTAssertEqual(bundlePosts.count, 2)
        // 第 2 次 POST 的 identifier 是通配 '*'
        let secondJSON = try JSONSerialization.jsonObject(with: try XCTUnwrap(bundlePosts.last?.body)) as! [String: Any]
        let secondAttrs = (secondJSON["data"] as! [String: Any])["attributes"] as! [String: Any]
        XCTAssertEqual(secondAttrs["identifier"] as? String, "*")
        // profile 引用的是通配 bundle 资源 WILD
        let profPost = mock.requests.last { $0.method == "POST" && $0.url.path.hasSuffix("v1/profiles") }
        let pJSON = try JSONSerialization.jsonObject(with: try XCTUnwrap(profPost?.body)) as! [String: Any]
        let rel = ((pJSON["data"] as! [String: Any])["relationships"]) as! [String: Any]
        let bundleRel = (rel["bundleId"] as! [String: Any])["data"] as! [String: Any]
        XCTAssertEqual(bundleRel["id"] as? String, "WILD")
    }

    /// 选了插件 → resign() 先调 performInjection，把其产物（而非原 IPA）交给 performResign；输出名 -injected.ipa
    func testResignInjectsWhenPluginSelectedAndNamesInjected() async throws {
        let profileData = Data([0xAB])
        let mock = MockHTTP { method, path in
            if path.hasSuffix("v1/bundleIds") {
                return method == "GET" ? MockHTTP.json(200, ["data": []])
                    : MockHTTP.json(201, ["data": ["id": "B1", "attributes": ["identifier": "com.demo.app", "name": "com.demo.app"]]])
            }
            if path.hasSuffix("v1/devices") { return MockHTTP.json(200, ["data": [["id": "D1", "attributes": ["udid": "u1", "name": "d1", "status": "ENABLED"]]]]) }
            if path.hasSuffix("v1/profiles") {
                return method == "GET" ? MockHTTP.json(200, ["data": []])
                    : MockHTTP.json(201, ["data": ["id": "P1", "attributes": ["name": "n", "profileContent": profileData.base64EncodedString()]]])
            }
            return MockHTTP.json(200, ["data": []])
        }
        let (m, idStore) = try makeModel(client: ASCClient(http: mock, signJWT: { _ in "T" }))
        let acc = AppleAccount(displayName: "A", keyID: "K", issuerID: "I")
        try m.store.add(acc); try m.secrets.save("PEM", for: acc.id); m.reload(); m.selectedID = acc.id
        try idStore.save(SigningIdentity(privateKeyDER: Data([1]), certificateDER: Data([2]), ascCertificateId: "CERT1"), for: acc.id)
        m.readBundleID = { _ in "com.demo.app" }
        m.revealInFinder = { _ in }
        m.selectedIPA = URL(fileURLWithPath: "/tmp/demo.ipa")
        m.selectedPlugin = URL(fileURLWithPath: "/tmp/FakeGPS.dylib")

        let sentinel = URL(fileURLWithPath: "/tmp/inject-xyz/injected.ipa")
        var injectInput: (URL, URL)?
        m.performInjection = { ipa, plugin in injectInput = (ipa, plugin); return sentinel }
        var signedInput: URL?
        m.performResign = { ipa, out, _, _ in signedInput = ipa; _ = out }

        await m.resign()

        XCTAssertNil(m.banner, "不应有错误：\(m.banner ?? "")")
        XCTAssertEqual(injectInput?.0, URL(fileURLWithPath: "/tmp/demo.ipa"))
        XCTAssertEqual(injectInput?.1, URL(fileURLWithPath: "/tmp/FakeGPS.dylib"))
        XCTAssertEqual(signedInput, sentinel, "选了插件应把注入产物交给签名")
        // 输出命名 -injected.ipa（源目录 /tmp 可写）
        XCTAssertEqual(ReSignModel.resolveOutputURL(for: m.selectedIPA!, injected: true),
                       URL(fileURLWithPath: "/tmp/demo-injected.ipa"))
    }

    /// defaultPerformInjection 端到端：合成 arm64 app + 插件 → 产出的临时 IPA 内主程序含注入的 LC_LOAD_DYLIB
    func testDefaultPerformInjectionEmbedsLoadCommand() throws {
        for t in ["/usr/bin/clang", "/usr/bin/otool", "/usr/bin/ditto"] {
            guard FileManager.default.isExecutableFile(atPath: t) else { throw XCTSkip("no \(t)") }
        }
        guard (try? BundledInjectTools.insertDylib) != nil else { throw XCTSkip("缺内置 insert_dylib") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 合成最小 IPA：Payload/Demo.app（arm64 主程序）
        let app = dir.appendingPathComponent("Payload/Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let main = app.appendingPathComponent("Demo")
        try Subprocess.runChecked("/usr/bin/clang", ["-arch", "arm64", "-o", main.path, "-x", "c", "-"],
            input: Data("int main(){return 0;}".utf8))
        try (["CFBundleIdentifier": "com.demo.app", "CFBundleExecutable": "Demo"] as NSDictionary)
            .write(to: app.appendingPathComponent("Info.plist"))
        let ipa = dir.appendingPathComponent("demo.ipa")
        try Subprocess.runChecked("/usr/bin/ditto",
            ["-c", "-k", "--sequesterRsrc", "--keepParent", dir.appendingPathComponent("Payload").path, ipa.path])
        // 合成插件 dylib
        let plugin = dir.appendingPathComponent("Plug.dylib")
        try Subprocess.runChecked("/usr/bin/clang", ["-arch", "arm64", "-dynamiclib", "-o", plugin.path, "-x", "c", "-"],
            input: Data("int plug(){return 1;}".utf8))

        let injected = try ReSignModel.defaultPerformInjection(ipaURL: ipa, plugin: plugin)
        defer { try? FileManager.default.removeItem(at: injected.deletingLastPathComponent()) }
        // 解包产物 → 主程序依赖应含注入的 dylib
        let out = dir.appendingPathComponent("out")
        try Subprocess.runChecked("/usr/bin/ditto", ["-x", "-k", injected.path, out.path])
        let outApp = try XCTUnwrap(IPAResigner.findPayloadApp(in: out))
        let deps = try MachOInspect.dylibDependencies(outApp.appendingPathComponent("Demo"))
        XCTAssertTrue(deps.contains { $0.contains("Plug.dylib") }, "主程序应加载注入的 dylib，实际：\(deps)")
    }

    /// 未选插件 → performInjection 不被调用，performResign 收到的是原 IPA（回归保护）
    func testResignSkipsInjectionWhenNoPlugin() async throws {
        let profileData = Data([0xAB])
        let mock = MockHTTP { method, path in
            if path.hasSuffix("v1/bundleIds") {
                return method == "GET" ? MockHTTP.json(200, ["data": []])
                    : MockHTTP.json(201, ["data": ["id": "B1", "attributes": ["identifier": "com.demo.app", "name": "com.demo.app"]]])
            }
            if path.hasSuffix("v1/devices") { return MockHTTP.json(200, ["data": [["id": "D1", "attributes": ["udid": "u1", "name": "d1", "status": "ENABLED"]]]]) }
            if path.hasSuffix("v1/profiles") {
                return method == "GET" ? MockHTTP.json(200, ["data": []])
                    : MockHTTP.json(201, ["data": ["id": "P1", "attributes": ["name": "n", "profileContent": profileData.base64EncodedString()]]])
            }
            return MockHTTP.json(200, ["data": []])
        }
        let (m, idStore) = try makeModel(client: ASCClient(http: mock, signJWT: { _ in "T" }))
        let acc = AppleAccount(displayName: "A", keyID: "K", issuerID: "I")
        try m.store.add(acc); try m.secrets.save("PEM", for: acc.id); m.reload(); m.selectedID = acc.id
        try idStore.save(SigningIdentity(privateKeyDER: Data([1]), certificateDER: Data([2]), ascCertificateId: "CERT1"), for: acc.id)
        m.readBundleID = { _ in "com.demo.app" }
        m.revealInFinder = { _ in }
        m.selectedIPA = URL(fileURLWithPath: "/tmp/demo.ipa")
        m.selectedPlugin = nil

        var injectCalled = false
        m.performInjection = { _, _ in injectCalled = true; return URL(fileURLWithPath: "/tmp/none") }
        var signedInput: URL?
        m.performResign = { ipa, _, _, _ in signedInput = ipa }

        await m.resign()

        XCTAssertNil(m.banner, "不应有错误：\(m.banner ?? "")")
        XCTAssertFalse(injectCalled, "未选插件不应调用注入")
        XCTAssertEqual(signedInput, URL(fileURLWithPath: "/tmp/demo.ipa"), "未选插件应直接签原 IPA")
    }

    /// 注入失败（如仍加密 IPA）→ 中文 banner，且不进入签名（InjectError 已本地化为中文）
    func testInjectionFailureShowsChineseBannerAndSkipsResign() async throws {
        let profileData = Data([0xAB])
        let mock = MockHTTP { method, path in
            if path.hasSuffix("v1/bundleIds") {
                return method == "GET" ? MockHTTP.json(200, ["data": []])
                    : MockHTTP.json(201, ["data": ["id": "B1", "attributes": ["identifier": "com.demo.app", "name": "com.demo.app"]]])
            }
            if path.hasSuffix("v1/devices") { return MockHTTP.json(200, ["data": [["id": "D1", "attributes": ["udid": "u1", "name": "d1", "status": "ENABLED"]]]]) }
            if path.hasSuffix("v1/profiles") {
                return method == "GET" ? MockHTTP.json(200, ["data": []])
                    : MockHTTP.json(201, ["data": ["id": "P1", "attributes": ["name": "n", "profileContent": profileData.base64EncodedString()]]])
            }
            return MockHTTP.json(200, ["data": []])
        }
        let (m, idStore) = try makeModel(client: ASCClient(http: mock, signJWT: { _ in "T" }))
        let acc = AppleAccount(displayName: "A", keyID: "K", issuerID: "I")
        try m.store.add(acc); try m.secrets.save("PEM", for: acc.id); m.reload(); m.selectedID = acc.id
        try idStore.save(SigningIdentity(privateKeyDER: Data([1]), certificateDER: Data([2]), ascCertificateId: "CERT1"), for: acc.id)
        m.readBundleID = { _ in "com.demo.app" }
        m.revealInFinder = { _ in }
        m.selectedIPA = URL(fileURLWithPath: "/tmp/demo.ipa")
        m.selectedPlugin = URL(fileURLWithPath: "/tmp/FakeGPS.dylib")

        m.performInjection = { _, _ in throw InjectError.encrypted }
        var resignCalled = false
        m.performResign = { _, _, _, _ in resignCalled = true }

        await m.resign()

        XCTAssertNotNil(m.banner, "注入失败应有 banner")
        XCTAssertTrue(m.banner?.contains("加密") == true || m.banner?.contains("脱壳") == true,
                      "banner 应为中文，实际：\(m.banner ?? "")")
        XCTAssertFalse(resignCalled, "注入失败不应继续签名")
    }
}
