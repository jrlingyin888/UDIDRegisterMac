import XCTest
@testable import ReSignKit

final class AppResignerTests: XCTestCase {
    func testResignSyntheticAppVerifiesAndCarriesEntitlements() throws {
        for tool in ["/usr/bin/codesign", "/usr/bin/openssl", "/usr/bin/security"] {
            guard FileManager.default.isExecutableFile(atPath: tool) else { throw XCTSkip("no \(tool)") }
        }
        let tmp = try TestTemp.dir(); defer { try? FileManager.default.removeItem(at: tmp) }
        // 合成最小 .app：Info.plist + 真实 mach-o 作为可执行文件
        let app = tmp.appendingPathComponent("Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "com.demo.app", "CFBundleExecutable": "Demo"] as NSDictionary)
            .write(to: app.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"),
                                         to: app.appendingPathComponent("Demo"))

        let fx = try TestSigningFixture.make(in: tmp); defer { fx.cleanup() }
        let id = try TemporaryKeychainIdentity(privateKey: fx.privateKey,
                                               certificateDER: fx.certificateDER, commonName: fx.commonName)
        defer { id.cleanup() }
        try id.addToSearchListForCodesign()

        let ent: [String: Any] = ["application-identifier": "TEAMID.com.demo.app", "get-task-allow": false]
        try AppResigner.resign(appDir: app, identity: id,
                               profileData: Data("FAKE-PROFILE".utf8), entitlements: ent)

        // 描述文件已写入
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("embedded.mobileprovision").path))
        // 验签通过
        let v = try Subprocess.run("/usr/bin/codesign", CodesignInvocation.verifyArgs(target: app.path) + ["--keychain", id.keychainPath])
        XCTAssertEqual(v.status, 0, "验签应通过：\(v.stderr)")
        // entitlements 落到了签名里
        let d = try Subprocess.run("/usr/bin/codesign", ["-d", "--entitlements", ":-", app.path])
        XCTAssertTrue(d.stdout.contains("com.demo.app"), "应能读回 entitlements")
    }
}
