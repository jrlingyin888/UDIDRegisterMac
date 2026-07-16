import XCTest
@testable import ReSignKit

final class AppBundleTests: XCTestCase {
    func testInsideOutOrderingPutsMainAppLast() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("abt-\(UUID().uuidString)")
        let app = tmp.appendingPathComponent("Sample.app")
        let fw = app.appendingPathComponent("Frameworks/Lib.framework")
        let dylib = app.appendingPathComponent("Frameworks/libx.dylib")
        let appex = app.appendingPathComponent("PlugIns/Ext.appex")
        for d in [fw, appex] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(at: dylib.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dylib.path, contents: Data([0xCF, 0xFA]))
        FileManager.default.createFile(atPath: app.appendingPathComponent("Info.plist").path, contents: Data())
        defer { try? FileManager.default.removeItem(at: tmp) }

        let targets = AppBundle(appDir: app).codeToSignInsideOut()
        XCTAssertEqual(targets.last, app, "主 app 必须最后签")
        // 三个嵌套项都在主 app 之前
        XCTAssertTrue(targets.contains(fw)); XCTAssertTrue(targets.contains(dylib)); XCTAssertTrue(targets.contains(appex))
        XCTAssertLessThan(targets.firstIndex(of: fw)!, targets.firstIndex(of: app)!)
        XCTAssertLessThan(targets.firstIndex(of: appex)!, targets.firstIndex(of: app)!)
    }
    func testBundleIdentifierReadsInfoPlist() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("abt2-\(UUID().uuidString)")
        let app = tmp.appendingPathComponent("S.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "com.a.b"] as NSDictionary).write(to: app.appendingPathComponent("Info.plist"))
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertEqual(try AppBundle(appDir: app).bundleIdentifier(), "com.a.b")
    }
}
