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

    /// C1：含 PlugIns/*.appex 的 app 必须拒签（而不是静默漏签扩展），
    /// 因为每个扩展需要自己独立的描述文件 + entitlements。
    func testResignRefusesAppWithNestedAppex() throws {
        for tool in ["/usr/bin/codesign", "/usr/bin/openssl", "/usr/bin/security"] {
            guard FileManager.default.isExecutableFile(atPath: tool) else { throw XCTSkip("no \(tool)") }
        }
        let tmp = try TestTemp.dir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let app = tmp.appendingPathComponent("Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "com.demo.app", "CFBundleExecutable": "Demo"] as NSDictionary)
            .write(to: app.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"),
                                         to: app.appendingPathComponent("Demo"))
        // 合成一个扩展 bundle：PlugIns/Ext.appex/Info.plist
        let appex = app.appendingPathComponent("PlugIns").appendingPathComponent("Ext.appex")
        try FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "com.demo.app.Ext", "CFBundleExecutable": "Ext"] as NSDictionary)
            .write(to: appex.appendingPathComponent("Info.plist"))

        let fx = try TestSigningFixture.make(in: tmp); defer { fx.cleanup() }
        let id = try TemporaryKeychainIdentity(privateKey: fx.privateKey,
                                               certificateDER: fx.certificateDER, commonName: fx.commonName)
        defer { id.cleanup() }
        try id.addToSearchListForCodesign()

        let ent: [String: Any] = ["application-identifier": "TEAMID.com.demo.app", "get-task-allow": false]
        XCTAssertThrowsError(try AppResigner.resign(appDir: app, identity: id,
                                                    profileData: Data("FAKE-PROFILE".utf8), entitlements: ent)) { error in
            guard case ReSignError.unsupportedNestedBundle(let names) = error else {
                return XCTFail("应抛出 unsupportedNestedBundle，实际：\(error)")
            }
            XCTAssertEqual(names, ["Ext.appex"])
        }
        // 未在拒签前留下已写入的描述文件（保证是“先检查后动作”，不是签一半再报错）
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("embedded.mobileprovision").path))
    }

    /// I1：profile-first 入口应从描述文件里派生 entitlements，而不是要求调用方另外传一份
    /// （避免越权：签上去的 entitlements 应与描述文件保持一致）。
    func testResignMobileprovisionDataDerivesEntitlementsFromProfile() throws {
        for tool in ["/usr/bin/codesign", "/usr/bin/openssl", "/usr/bin/security"] {
            guard FileManager.default.isExecutableFile(atPath: tool) else { throw XCTSkip("no \(tool)") }
        }
        let tmp = try TestTemp.dir(); defer { try? FileManager.default.removeItem(at: tmp) }

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

        // 用 security cms -S 造一张真正签过的 .mobileprovision（同 ProvisioningProfileTests 的模式）
        let plist = tmp.appendingPathComponent("in.plist")
        try (["Entitlements": ["application-identifier": "T.com.demo.app", "get-task-allow": false],
              "Name": "n", "UUID": "u"] as NSDictionary)
            .write(to: plist)
        let signed = tmp.appendingPathComponent("p.mobileprovision")
        try Subprocess.runChecked("/usr/bin/security",
            ["cms", "-S", "-N", fx.commonName, "-u", "6", "-k", fx.keychainPath, "-i", plist.path, "-o", signed.path])
        let mobileprovisionData = try Data(contentsOf: signed)

        try AppResigner.resign(appDir: app, identity: id, mobileprovisionData: mobileprovisionData)

        // 描述文件已写入
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("embedded.mobileprovision").path))
        // entitlements 是从描述文件派生并落到签名里的
        let d = try Subprocess.run("/usr/bin/codesign", ["-d", "--entitlements", ":-", app.path])
        XCTAssertTrue(d.stdout.contains("com.demo.app"), "应能读回从描述文件派生的 entitlements：\(d.stdout)")
    }
}
