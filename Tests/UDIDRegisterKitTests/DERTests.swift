import XCTest
@testable import UDIDRegisterKit

final class DERTests: XCTestCase {
    func testLengthShortForm() {
        XCTAssertEqual(DER.length(0), [0x00])
        XCTAssertEqual(DER.length(127), [0x7f])
    }
    func testLengthLongForm() {
        XCTAssertEqual(DER.length(128), [0x81, 0x80])
        XCTAssertEqual(DER.length(200), [0x81, 0xc8])
        XCTAssertEqual(DER.length(256), [0x82, 0x01, 0x00])
    }
    func testIntegerZeroAndHighBit() {
        XCTAssertEqual(DER.integer([0x00]), [0x02, 0x01, 0x00])
        // 最高位为 1 需前置 0x00 防止被读成负数
        XCTAssertEqual(DER.integer([0x80]), [0x02, 0x02, 0x00, 0x80])
    }
    func testOIDandSequence() {
        XCTAssertEqual(DER.oid([0x55, 0x04, 0x03]), [0x06, 0x03, 0x55, 0x04, 0x03])
        XCTAssertEqual(DER.sequence([DER.integer([0x00])]), [0x30, 0x03, 0x02, 0x01, 0x00])
    }
    func testBitStringPrependsUnusedBitCount() {
        XCTAssertEqual(DER.bitString([0xAB]), [0x03, 0x02, 0x00, 0xAB])
    }
    func testContextConstructedEmpty() {
        XCTAssertEqual(DER.contextConstructed(0, []), [0xA0, 0x00])
        XCTAssertEqual(DER.contextConstructed(3, [0x01]), [0xA3, 0x01, 0x01])
    }
    func testSetNullAndStrings() {
        XCTAssertEqual(DER.set([DER.integer([0x00])]), [0x31, 0x03, 0x02, 0x01, 0x00])
        XCTAssertEqual(DER.null(), [0x05, 0x00])
        XCTAssertEqual(DER.utf8String("A"), [0x0C, 0x01, 0x41])
        XCTAssertEqual(DER.printableString("A"), [0x13, 0x01, 0x41])
    }
}
