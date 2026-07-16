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
}
