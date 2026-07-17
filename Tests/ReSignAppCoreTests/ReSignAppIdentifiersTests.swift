import XCTest
@testable import ReSignAppCore
import UDIDRegisterKit

final class ReSignAppIdentifiersTests: XCTestCase {
    func testBundleIDValueAndDistinctFromRegisterApp() {
        XCTAssertEqual(ReSignAppIdentifiers.bundleID, "com.pangu.ReSignMac")
        XCTAssertNotEqual(ReSignAppIdentifiers.bundleID, AppIdentifiers.bundleID)
    }
}
