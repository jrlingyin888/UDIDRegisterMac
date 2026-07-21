import XCTest
@testable import ReSignKit

final class DylibInjectorTests: XCTestCase {
    // 用 clang 造 arm64 主程序 + 插件 dylib，拼一个最小 .app
    func makeSyntheticApp(in dir: URL) throws -> URL {
        let app = dir.appendingPathComponent("Payload/Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let main = app.appendingPathComponent("Demo")
        try Subprocess.runChecked("/usr/bin/clang", ["-arch", "arm64", "-o", main.path, "-x", "c", "-"],
            input: Data("int main(){return 0;}".utf8))
        let info = app.appendingPathComponent("Info.plist")
        try "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleExecutable</key><string>Demo</string></dict></plist>".write(to: info, atomically: true, encoding: .utf8)
        return app
    }
    func makePluginDylib(at url: URL) throws {
        try Subprocess.runChecked("/usr/bin/clang", ["-arch", "arm64", "-dynamiclib", "-o", url.path, "-x", "c", "-"],
            input: Data("int plugin_init(){return 1;}".utf8))
    }

    func testInjectAddsLoadCommandAndCopiesDylib() throws {
        for t in ["/usr/bin/clang", "/usr/bin/otool"] { guard FileManager.default.isExecutableFile(atPath: t) else { throw XCTSkip("no \(t)") } }
        let insertTool = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/inject/insert_dylib")
        guard FileManager.default.isExecutableFile(atPath: insertTool.path) else { throw XCTSkip("no bundled insert_dylib（Task 1 先做）") }
        let dir = try TestTemp.dir(); defer { try? FileManager.default.removeItem(at: dir) }
        let app = try makeSyntheticApp(in: dir)
        let plugin = dir.appendingPathComponent("FakeGPS.dylib"); try makePluginDylib(at: plugin)

        let target = try DylibInjector.preflight(appDir: app)   // 干净 clang 二进制 → 不加密、arm64
        try DylibInjector.inject(plugin: plugin, into: target, insertDylibTool: insertTool, substrateReplacement: nil)

        // 断言：dylib 已拷进 Frameworks/
        let embedded = app.appendingPathComponent("Frameworks/FakeGPS.dylib")
        XCTAssertTrue(FileManager.default.fileExists(atPath: embedded.path))
        // 断言：主程序多了指向该 dylib 的 LC_LOAD_DYLIB
        let deps = try MachOInspect.dylibDependencies(target.mainExecutable)
        XCTAssertTrue(deps.contains { $0.contains("FakeGPS.dylib") }, "主程序应加载注入的 dylib，实际依赖：\(deps)")
    }

    func testPreflightRejectsMissingApp() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try DylibInjector.preflight(appDir: dir)) { XCTAssertEqual($0 as? InjectError, .notApp) }
    }
}
