import XCTest
@testable import UDIDRegisterKit

final class ASCSigningClientTests: XCTestCase {
    let cred = ASCCredentials(keyID: "K", issuerID: "I", privateKeyPEM: "PEM")
    func makeClient(_ h: @escaping (String, String) -> HTTPResponse) -> ASCClient {
        ASCClient(http: MockHTTP(h), signJWT: { _ in "TESTTOKEN" })
    }

    func testFindOrCreateBundleIdReturnsExisting() async throws {
        let c = makeClient { method, path in
            XCTAssertEqual(method, "GET")
            return MockHTTP.json(200, ["data": [["id": "B9",
                "attributes": ["identifier": "com.a.b", "name": "AB"]]]])
        }
        let info = try await c.findOrCreateBundleId(credentials: cred, identifier: "com.a.b", name: "AB")
        XCTAssertEqual(info.id, "B9")
    }
    func testFindOrCreateBundleIdCreatesWhenMissing() async throws {
        let c = makeClient { method, _ in
            if method == "GET" { return MockHTTP.json(200, ["data": []]) }
            return MockHTTP.json(201, ["data": ["id": "Bnew",
                "attributes": ["identifier": "com.a.b", "name": "AB"]]])
        }
        let info = try await c.findOrCreateBundleId(credentials: cred, identifier: "com.a.b", name: "AB")
        XCTAssertEqual(info.id, "Bnew")
    }
    func testCreateBundleIdPropagatesError() async throws {
        let c = makeClient { _, _ in MockHTTP.json(409, ["errors": [["detail": "重复"]]]) }
        do { _ = try await c.createBundleId(credentials: cred, identifier: "x", name: "x"); XCTFail() }
        catch let ASCError.http(status, detail) { XCTAssertEqual(status, 409); XCTAssertEqual(detail, "重复") }
    }
    func testCreateCertificateSendsPEMandParsesContent() async throws {
        let der = Data([0x30, 0x01, 0x00])
        let c = makeClient { method, path in
            XCTAssertEqual(method, "POST")
            XCTAssertTrue(path.hasSuffix("v1/certificates"))
            return MockHTTP.json(201, ["data": ["id": "C1",
                "attributes": ["name": "Dist", "certificateContent": der.base64EncodedString()]]])
        }
        let info = try await c.createCertificate(credentials: cred,
                                                 csrDER: Data([0xDE, 0xAD]), type: .distribution)
        XCTAssertEqual(info.id, "C1")
        XCTAssertEqual(info.contentDER, der)
    }
    func testPemCSRWrapsHeaderFooter() {
        let pem = ASCClient.pemCSR(Data([0x00, 0x01]))
        XCTAssertTrue(pem.hasPrefix("-----BEGIN CERTIFICATE REQUEST-----"))
        XCTAssertTrue(pem.contains("-----END CERTIFICATE REQUEST-----"))
    }
    func testRefreshDeletesOldThenCreates() async throws {
        // 同步、加锁的记录器（不要用 detached Task，会与断言竞态）
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock(); private var log: [String] = []
            func add(_ s: String) { lock.lock(); log.append(s); lock.unlock() }
            var entries: [String] { lock.lock(); defer { lock.unlock() }; return log }
        }
        let rec = Recorder()
        let der = Data([0x0A, 0x0B])
        let c = ASCClient(http: MockHTTP { method, path in
            rec.add("\(method) \(path)")
            if method == "GET" {  // listProfiles 返回一个旧的同名 profile
                return MockHTTP.json(200, ["data": [["id": "OLD", "attributes": ["name": "n"]]]])
            }
            if method == "DELETE" { return HTTPResponse(status: 204, body: Data()) }
            return MockHTTP.json(201, ["data": ["id": "NEW",
                "attributes": ["name": "n", "uuid": "U", "profileContent": der.base64EncodedString()]]])
        }, signJWT: { _ in "T" })

        let info = try await c.refreshAdHocProfile(credentials: cred, name: "n",
            bundleIdResourceId: "B", certificateId: "C", deviceIds: ["D1", "D2"])
        XCTAssertEqual(info.id, "NEW")
        XCTAssertEqual(info.contentData, der)
        // DELETE 命中旧 profile 路径（同步记录，无竞态）
        XCTAssertTrue(rec.entries.contains { $0.hasPrefix("DELETE") && $0.contains("v1/profiles/OLD") })
    }
    func testCreateAdHocProfileParsesContent() async throws {
        let der = Data([0x77])
        let c = makeClient { _, _ in
            MockHTTP.json(201, ["data": ["id": "P",
                "attributes": ["name": "n", "profileContent": der.base64EncodedString()]]])
        }
        let info = try await c.createAdHocProfile(credentials: cred, name: "n",
            bundleIdResourceId: "B", certificateId: "C", deviceIds: ["D1"])
        XCTAssertEqual(info.contentData, der)
    }

    // MARK: - 请求体/查询串断言（MockHTTP 现在记录请求）
    func testCreateCertificateSendsPEMcsrContentInBody() async throws {
        let mock = MockHTTP { _, _ in
            MockHTTP.json(201, ["data": ["id": "C1", "attributes":
                ["name": "Dist", "certificateContent": Data([0x30]).base64EncodedString()]]])
        }
        let c = ASCClient(http: mock, signJWT: { _ in "T" })
        _ = try await c.createCertificate(credentials: cred, csrDER: Data([0xDE, 0xAD]), type: .distribution)
        let body = try XCTUnwrap(mock.requests.last?.body)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let attrs = (json["data"] as! [String: Any])["attributes"] as! [String: Any]
        XCTAssertTrue((attrs["csrContent"] as! String).hasPrefix("-----BEGIN CERTIFICATE REQUEST-----"))
        XCTAssertEqual(attrs["certificateType"] as? String, "DISTRIBUTION")
    }

    func testCreateAdHocProfileSendsRelationshipsShape() async throws {
        let mock = MockHTTP { _, _ in
            MockHTTP.json(201, ["data": ["id": "P", "attributes":
                ["name": "n", "profileContent": Data([0x77]).base64EncodedString()]]])
        }
        let c = ASCClient(http: mock, signJWT: { _ in "T" })
        _ = try await c.createAdHocProfile(credentials: cred, name: "n",
            bundleIdResourceId: "B", certificateId: "C", deviceIds: ["D1", "D2"])
        let body = try XCTUnwrap(mock.requests.last?.body)
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let data = json["data"] as! [String: Any]
        XCTAssertEqual((data["attributes"] as! [String: Any])["profileType"] as? String, "IOS_APP_ADHOC")
        let rel = data["relationships"] as! [String: Any]
        let bundle = (rel["bundleId"] as! [String: Any])["data"] as! [String: Any]  // to-one 对象
        XCTAssertEqual(bundle["type"] as? String, "bundleIds")
        XCTAssertEqual(bundle["id"] as? String, "B")
        let certs = (rel["certificates"] as! [String: Any])["data"] as! [[String: Any]]  // to-many 数组
        XCTAssertEqual(certs.first?["id"] as? String, "C")
        let devs = (rel["devices"] as! [String: Any])["data"] as! [[String: Any]]
        XCTAssertEqual(devs.map { $0["id"] as? String }, ["D1", "D2"])
    }

    func testListBundleIdsSendsIdentifierFilterQuery() async throws {
        let mock = MockHTTP { _, _ in MockHTTP.json(200, ["data": []]) }
        let c = ASCClient(http: mock, signJWT: { _ in "T" })
        _ = try await c.listBundleIds(credentials: cred, identifier: "com.a.b")
        let url = try XCTUnwrap(mock.requests.last?.url)
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(q.contains { $0.name == "filter[identifier]" && $0.value == "com.a.b" })
    }

    func testCreateCertificateThrowsOnMissingContent() async throws {
        let c = makeClient { _, _ in MockHTTP.json(201, ["data": ["id": "C1", "attributes": ["name": "Dist"]]]) }
        do { _ = try await c.createCertificate(credentials: cred, csrDER: Data([0x00]), type: .distribution); XCTFail("应抛错") }
        catch let ASCError.http(status, detail) { XCTAssertEqual(status, 201); XCTAssertTrue(detail.contains("内容")) }
    }

    func testCreateAdHocProfileThrowsOnMissingContent() async throws {
        let c = makeClient { _, _ in MockHTTP.json(201, ["data": ["id": "P", "attributes": ["name": "n"]]]) }
        do { _ = try await c.createAdHocProfile(credentials: cred, name: "n",
            bundleIdResourceId: "B", certificateId: "C", deviceIds: ["D1"]); XCTFail("应抛错") }
        catch let ASCError.http(status, detail) { XCTAssertEqual(status, 201); XCTAssertTrue(detail.contains("内容")) }
    }
}
