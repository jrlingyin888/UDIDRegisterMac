import XCTest
@testable import ReSignKit

final class IPAResignerTests: XCTestCase {
    func testResignIPARoundTripsAndVerifies() throws {
        for tool in ["/usr/bin/ditto", "/usr/bin/codesign", "/usr/bin/openssl", "/usr/bin/security"] {
            guard FileManager.default.isExecutableFile(atPath: tool) else { throw XCTSkip("no \(tool)") }
        }
        let tmp = try TestTemp.dir(); defer { try? FileManager.default.removeItem(at: tmp) }
        // 合成 Payload/Demo.app 并 ditto 打成 .ipa
        let payload = tmp.appendingPathComponent("Payload")
        let app = payload.appendingPathComponent("Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "com.demo.app", "CFBundleExecutable": "Demo"] as NSDictionary)
            .write(to: app.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: app.appendingPathComponent("Demo"))
        let ipa = tmp.appendingPathComponent("in.ipa")
        try Subprocess.runChecked("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", payload.path, ipa.path])

        let fx = try TestSigningFixture.make(in: tmp); defer { fx.cleanup() }
        let id = try TemporaryKeychainIdentity(privateKey: fx.privateKey,
                                               certificateDER: fx.certificateDER, commonName: fx.commonName)
        defer { id.cleanup() }
        try id.addToSearchListForCodesign()

        let out = tmp.appendingPathComponent("out.ipa")
        try IPAResigner.resign(ipaURL: ipa, outputURL: out, identity: id,
                               profileData: Data("FAKE".utf8),
                               entitlements: ["application-identifier": "T.com.demo.app"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        // 解开输出，验签
        let check = tmp.appendingPathComponent("check")
        try Subprocess.runChecked("/usr/bin/ditto", ["-x", "-k", out.path, check.path])
        let outApp = check.appendingPathComponent("Payload/Demo.app")
        let v = try Subprocess.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", outApp.path, "--keychain", id.keychainPath])
        XCTAssertEqual(v.status, 0, "重签后的 IPA 应验签通过：\(v.stderr)")
    }

    func testFindPayloadAppNilWhenMissing() throws {
        let tmp = try TestTemp.dir(); defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertNil(IPAResigner.findPayloadApp(in: tmp))
    }

    func testReadBundleIdentifierFromIPA() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ditto") else { throw XCTSkip("no ditto") }
        let tmp = try TestTemp.dir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let payload = tmp.appendingPathComponent("Payload")
        let app = payload.appendingPathComponent("Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "com.demo.peek", "CFBundleExecutable": "Demo"] as NSDictionary)
            .write(to: app.appendingPathComponent("Info.plist"))
        let ipa = tmp.appendingPathComponent("in.ipa")
        try Subprocess.runChecked("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", payload.path, ipa.path])

        XCTAssertEqual(try IPAResigner.readBundleIdentifier(ipaURL: ipa), "com.demo.peek")
    }
}
