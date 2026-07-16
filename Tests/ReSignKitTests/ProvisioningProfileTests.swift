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

    func testDecodePlistRoundTripsViaSecurityCMS() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/security"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") else { throw XCTSkip("no tools") }
        let tmp = try TestTemp.dir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let plist = tmp.appendingPathComponent("in.plist")
        try (["Entitlements": ["application-identifier": "T.com.a.b"], "Name": "n", "UUID": "u"] as NSDictionary)
            .write(to: plist)
        let fx = try TestSigningFixture.make(in: tmp); defer { fx.cleanup() }
        let signed = tmp.appendingPathComponent("p.mobileprovision")
        // -u 6 = certUsageObjectSigner:默认 certUsageEmailSigner 要求身份被系统信任(且带
        // email 相关 EKU),自签的 codeSigning 身份会报 "could not find signing identity for
        // name"。ObjectSigner 语义上贴合"给一个对象签名"且不要求信任链,无需 add-trusted-cert。
        try Subprocess.runChecked("/usr/bin/security",
            ["cms", "-S", "-N", fx.commonName, "-u", "6", "-k", fx.keychainPath, "-i", plist.path, "-o", signed.path])
        let decoded = try ProvisioningProfile.decodePlist(fromMobileprovision: signed)
        XCTAssertEqual(decoded["Name"] as? String, "n")
        let profile = try ProvisioningProfile.load(fromMobileprovision: signed)
        XCTAssertEqual(profile.entitlements["application-identifier"] as? String, "T.com.a.b")
    }
}
