import XCTest
@testable import ReSignKit

final class CodesignInvocationTests: XCTestCase {
    func testSignArgsWithEntitlements() {
        let a = CodesignInvocation.signArgs(identity: "ABC123", target: "/x/A.app", entitlements: "/tmp/e.plist")
        XCTAssertEqual(a.first, "--force")
        XCTAssertEqual(a[1], "--sign"); XCTAssertEqual(a[2], "ABC123")
        XCTAssertTrue(a.contains("--entitlements")); XCTAssertTrue(a.contains("/tmp/e.plist"))
        XCTAssertEqual(a.last, "/x/A.app")
    }
    func testSignArgsWithoutEntitlementsOmitsFlag() {
        let a = CodesignInvocation.signArgs(identity: "ABC123", target: "/x/lib.dylib", entitlements: nil)
        XCTAssertFalse(a.contains("--entitlements"))
        XCTAssertEqual(a.last, "/x/lib.dylib")
    }
    func testVerifyArgs() {
        XCTAssertEqual(CodesignInvocation.verifyArgs(target: "/x/A.app"),
                       ["--verify", "--deep", "--strict", "--verbose=2", "/x/A.app"])
    }
}
