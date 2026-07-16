import XCTest
import Security
@testable import ReSignKit

final class TemporaryKeychainIdentityTests: XCTestCase {
    func testImportedIdentityCanCodesignAFileWithoutPrompt() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/codesign"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/security") else { throw XCTSkip("no tools") }
        let tmp = try TestTemp.dir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let fx = try TestSigningFixture.make(in: tmp); defer { fx.cleanup() }

        // 用一个真实 mach-o（拷贝 /bin/echo）作为待签目标
        let target = tmp.appendingPathComponent("echo-copy")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: target)

        let id = try TemporaryKeychainIdentity(privateKey: fx.privateKey,
                                               certificateDER: fx.certificateDER, commonName: fx.commonName)
        defer { id.cleanup() }
        try id.addToSearchListForCodesign()
        // 无弹窗签名:codesign 退出 0
        let r = try Subprocess.run("/usr/bin/codesign",
            CodesignInvocation.signArgs(identity: id.signingIdentity, target: target.path, entitlements: nil)
            + ["--keychain", id.keychainPath])
        XCTAssertEqual(r.status, 0, "签名应无弹窗且成功:\(r.stderr)")
        let v = try Subprocess.run("/usr/bin/codesign", ["--verify", "--verbose=2", target.path])
        XCTAssertEqual(v.status, 0, "验签应通过:\(v.stderr)")
    }
}
