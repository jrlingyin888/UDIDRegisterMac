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
}
