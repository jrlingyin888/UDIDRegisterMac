import XCTest
@testable import ReSignKit

final class SubprocessTests: XCTestCase {
    func testRunCapturesStdoutAndStatus() throws {
        let r = try Subprocess.run("/bin/echo", ["hello"])
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.stdout, "hello\n")
    }
    func testRunCheckedThrowsOnNonZero() throws {
        // /usr/bin/false 退出码 1
        XCTAssertThrowsError(try Subprocess.runChecked("/usr/bin/false", [])) { err in
            guard case SubprocessError.nonZero(let status, _) = err else { return XCTFail("wrong error") }
            XCTAssertEqual(status, 1)
        }
    }
    func testRunFeedsStdin() throws {
        // cat 回显 stdin
        let r = try Subprocess.run("/bin/cat", [], input: Data("abc".utf8))
        XCTAssertEqual(r.stdout, "abc")
    }
}
