import XCTest
@testable import UDIDRegisterKit

final class SigningModelsTests: XCTestCase {
    func testBundleIdInfoParsesOrNil() {
        let ok = BundleIdInfo(json: ["id": "B1", "attributes": ["identifier": "com.a.b", "name": "AB"]])
        XCTAssertEqual(ok?.id, "B1")
        XCTAssertEqual(ok?.identifier, "com.a.b")
        XCTAssertNil(BundleIdInfo(json: ["id": "B1"]))  // 缺 attributes → nil
    }
    func testCertificateInfoDecodesBase64Content() {
        let der = Data([0x30, 0x01, 0x00])
        let info = CertificateInfo(json: ["id": "C1",
            "attributes": ["name": "Dist", "certificateContent": der.base64EncodedString()]])
        XCTAssertEqual(info?.contentDER, der)
    }
    func testProfileInfoDecodesContentAndUUID() {
        let der = Data([0x01, 0x02, 0x03])
        let info = ProfileInfo(json: ["id": "P1",
            "attributes": ["name": "AdHoc", "uuid": "U-1", "profileContent": der.base64EncodedString()]])
        XCTAssertEqual(info?.uuid, "U-1")
        XCTAssertEqual(info?.contentData, der)
    }
}
