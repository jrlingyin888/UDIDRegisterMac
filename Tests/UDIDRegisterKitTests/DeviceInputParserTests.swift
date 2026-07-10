import XCTest
@testable import UDIDRegisterKit

final class DeviceInputParserTests: XCTestCase {
    func testSplitsLinesAndNames() {
        let inputs = DeviceInputParser.parse("00008110-001C24CC14FA601E, 张三 iPhone\n" +
                                             "  \n" +
                                             "abc123, 李四")
        XCTAssertEqual(inputs.count, 2)
        XCTAssertEqual(inputs[0].udidRaw, "00008110-001C24CC14FA601E")
        XCTAssertEqual(inputs[0].name, "张三 iPhone")
        XCTAssertEqual(inputs[1].udidRaw, "abc123")
        XCTAssertEqual(inputs[1].name, "李四")
    }
    func testDefaultNameWhenMissing() {
        let inputs = DeviceInputParser.parse("00008110-001C24CC14FA601E")
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs[0].name, "Device-FA601E")
    }
    func testEmptyNameAfterCommaGetsDefault() {
        let inputs = DeviceInputParser.parse("00008110-001C24CC14FA601E,   ")
        XCTAssertEqual(inputs[0].name, "Device-FA601E")
    }
    func testDropsLinesWithNoUdid() {
        XCTAssertTrue(DeviceInputParser.parse(",name\n\n").isEmpty)
    }
}
