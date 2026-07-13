import XCTest
@testable import UDIDRegisterKit

final class AccountConfigTests: XCTestCase {
    private func sample() -> AccountConfig {
        AccountConfig(schemaVersion: 1, displayName: "公司主账号", keyID: "QA2MC7L8X7",
                      issuerID: "11111111-2222-3333-4444-555555555555", teamID: "ABCDE12345",
                      p8PEM: "-----BEGIN PRIVATE KEY-----\nMFAKE\n-----END PRIVATE KEY-----\n")
    }
    func testRoundTrip() throws {
        let data = try AccountConfigCodec.encode(sample())
        XCTAssertEqual(try AccountConfigCodec.decode(data), sample())
    }
    func testNilTeamIDRoundTrips() throws {
        var c = sample(); c.teamID = nil
        let data = try AccountConfigCodec.encode(c)
        XCTAssertEqual(try AccountConfigCodec.decode(data), c)
    }
    func testUnsupportedVersion() throws {
        var c = sample(); c.schemaVersion = 2
        let data = try AccountConfigCodec.encode(c)
        XCTAssertThrowsError(try AccountConfigCodec.decode(data)) {
            guard case AccountConfigError.unsupportedVersion(2) = $0 else { return XCTFail("wrong error: \($0)") }
        }
    }
    func testMalformedJSON() {
        XCTAssertThrowsError(try AccountConfigCodec.decode(Data("not json".utf8))) {
            guard case AccountConfigError.malformed = $0 else { return XCTFail("wrong error: \($0)") }
        }
    }
    func testMissingFieldIsMalformed() {
        let json = #"{"schemaVersion":1,"displayName":"x","issuerID":"y","p8PEM":"-----BEGIN PRIVATE KEY-----"}"#
        XCTAssertThrowsError(try AccountConfigCodec.decode(Data(json.utf8))) {
            guard case AccountConfigError.malformed = $0 else { return XCTFail("wrong error: \($0)") }
        }
    }
    func testEmptyPEMIsMalformed() throws {
        var c = sample(); c.p8PEM = ""
        let data = try AccountConfigCodec.encode(c)
        XCTAssertThrowsError(try AccountConfigCodec.decode(data)) {
            guard case AccountConfigError.malformed = $0 else { return XCTFail("wrong error: \($0)") }
        }
    }
}
