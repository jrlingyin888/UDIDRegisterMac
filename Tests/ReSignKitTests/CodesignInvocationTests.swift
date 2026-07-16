import XCTest
@testable import ReSignKit

final class CodesignInvocationTests: XCTestCase {
    func testSignArgsWithEntitlements() {
        let a = CodesignInvocation.signArgs(identity: "ABC123", target: "/x/A.app", entitlements: "/tmp/e.plist")
        XCTAssertEqual(a, ["--force", "--sign", "ABC123", "--entitlements", "/tmp/e.plist", "--timestamp=none", "/x/A.app"])
    }
    func testSignArgsWithoutEntitlementsOmitsFlag() {
        let a = CodesignInvocation.signArgs(identity: "ABC123", target: "/x/lib.dylib", entitlements: nil)
        XCTAssertEqual(a, ["--force", "--sign", "ABC123", "--timestamp=none", "/x/lib.dylib"])
    }
    func testVerifyArgs() {
        XCTAssertEqual(CodesignInvocation.verifyArgs(target: "/x/A.app"),
                       ["--verify", "--deep", "--strict", "--verbose=2", "/x/A.app"])
    }
}
