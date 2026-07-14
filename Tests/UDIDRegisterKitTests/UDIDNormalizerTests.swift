import XCTest
@testable import UDIDRegisterKit

final class UDIDNormalizerTests: XCTestCase {
    func testModernUppercased() {
        XCTAssertEqual(UDIDNormalizer.normalize("00008110-001c24cc14fa601e"), "00008110-001C24CC14FA601E")
    }
    func testModernAlreadyUpper() {
        XCTAssertEqual(UDIDNormalizer.normalize("00008110-001C24CC14FA601E"), "00008110-001C24CC14FA601E")
    }
    func testLegacyLowercased() {
        let u = String(repeating: "a", count: 40)
        XCTAssertEqual(UDIDNormalizer.normalize(u.uppercased()), u)
    }
    func testTrimsWhitespace() {
        XCTAssertEqual(UDIDNormalizer.normalize("  00008110-001C24CC14FA601E \n"), "00008110-001C24CC14FA601E")
    }
    func testInvalidReturnsNil() {
        XCTAssertNil(UDIDNormalizer.normalize("not-a-udid"))
        XCTAssertNil(UDIDNormalizer.normalize("00008110-001C24CC14FA601"))   // 15 位尾段
        XCTAssertNil(UDIDNormalizer.normalize(String(repeating: "z", count: 40)))
    }
}
