import XCTest
@testable import UDIDRegisterKit

final class AppIdentifiersTests: XCTestCase {
    func testBundleIDValue() {
        XCTAssertEqual(AppIdentifiers.bundleID, "com.pangu.UDIDRegisterMac")
    }
    func testKeychainStoreUsesBundleIDByDefault() {
        XCTAssertEqual(KeychainSecretStore().service, AppIdentifiers.bundleID)
    }
}
