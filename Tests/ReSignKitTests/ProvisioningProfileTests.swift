import XCTest
@testable import ReSignKit

final class ProvisioningProfileTests: XCTestCase {
    func testInitParsesEntitlementsAndFields() throws {
        let plist: [String: Any] = [
            "Name": "AdHoc-com.a.b",
            "UUID": "ABCD-1234",
            "TeamIdentifier": ["TEAMID9"],
            "ProvisionedDevices": ["udid1", "udid2"],
            "Entitlements": [
                "application-identifier": "TEAMID9.com.a.b",
                "get-task-allow": false
            ]
        ]
        let p = try XCTUnwrap(ProvisioningProfile(plist: plist))
        XCTAssertEqual(p.name, "AdHoc-com.a.b")
        XCTAssertEqual(p.uuid, "ABCD-1234")
        XCTAssertEqual(p.teamIdentifier, "TEAMID9")
        XCTAssertEqual(p.deviceUDIDs, ["udid1", "udid2"])
        XCTAssertEqual(p.entitlements["application-identifier"] as? String, "TEAMID9.com.a.b")
    }
    func testInitNilWhenNoEntitlements() {
        XCTAssertNil(ProvisioningProfile(plist: ["Name": "x", "UUID": "y"]))
    }
}
