import XCTest
@testable import UDIDRegisterKit

final class ASCClientTests: XCTestCase {
    let cred = ASCCredentials(keyID: "K", issuerID: "I", privateKeyPEM: "PEM")
    func makeClient(_ h: @escaping (String, String) -> HTTPResponse) -> ASCClient {
        ASCClient(http: MockHTTP(h), signJWT: { _ in "TESTTOKEN" })  // 跳过真实签名
    }

    func testCreatedReturnsStatus() async throws {
        let c = makeClient { _, _ in
            MockHTTP.json(201, ["data": ["id": "X", "attributes": ["status": "PROCESSING"]]])
        }
        let out = try await c.registerDevice(credentials: cred, name: "n", udid: "U")
        XCTAssertEqual(out, .created(status: .processing))
    }
    func testConflictLooksUpStatusAndName() async throws {
        let c = makeClient { method, _ in
            if method == "POST" { return MockHTTP.json(409, ["errors": [["detail": "exists"]]]) }
            return MockHTTP.json(200, ["data": [["id": "X",
                "attributes": ["udid": "00008110-001C24CC14FA601E", "name": "iPhone", "status": "ENABLED"]]]])
        }
        let out = try await c.registerDevice(credentials: cred, name: "newxp15", udid: "00008110-001C24CC14FA601E")
        XCTAssertEqual(out, .alreadyExisted(name: "iPhone", status: .enabled))
    }
    func testConflictNotFoundFallsBackToError() async throws {
        let c = makeClient { method, _ in
            if method == "POST" { return MockHTTP.json(409, ["errors": [["detail": "already exists"]]]) }
            return MockHTTP.json(200, ["data": []])
        }
        let out = try await c.registerDevice(credentials: cred, name: "n", udid: "U")
        XCTAssertEqual(out, .failed(message: "already exists"))
    }
    func testServerErrorFails() async throws {
        let c = makeClient { _, _ in MockHTTP.json(500, ["errors": [["detail": "boom"]]]) }
        let out = try await c.registerDevice(credentials: cred, name: "n", udid: "U")
        XCTAssertEqual(out, .failed(message: "boom"))
    }
    func testListDevicesMapsRows() async throws {
        let c = makeClient { _, _ in
            MockHTTP.json(200, ["data": [["id": "A", "attributes":
                ["udid": "u1", "name": "d1", "status": "ENABLED", "model": "iPhone 14"]]]])
        }
        let rows = try await c.listDevices(credentials: cred)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].status, .enabled)
        XCTAssertEqual(rows[0].model, "iPhone 14")
    }
}
