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
    func testHandlesLargeConcurrentStdoutStderrWithoutDeadlock() throws {
        // yes 快速产生大量 stdout；head 截断。用 sh 同时向 stdout/stderr 各写 >64KB。
        let script = "for i in $(seq 1 4000); do echo stdoutline$i; echo errline$i 1>&2; done"
        let r = try Subprocess.run("/bin/sh", ["-c", script])
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(r.stdout.contains("stdoutline4000"))
        XCTAssertTrue(r.stderr.contains("errline4000"))
    }
}
