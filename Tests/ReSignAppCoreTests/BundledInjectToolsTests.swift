import XCTest
@testable import ReSignAppCore
import ReSignKit

final class BundledInjectToolsTests: XCTestCase {
    func testResolvesBundledInsertDylibAndEllekit() throws {
        let insert = try BundledInjectTools.insertDylib
        let elle = try BundledInjectTools.ellekit
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: insert.path),
                      "insert_dylib 应可执行：\(insert.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: elle.path),
                      "ElleKit.dylib 应存在：\(elle.path)")
        let archs = try MachOInspect.archs(elle)
        XCTAssertTrue(archs.contains("arm64"), "ElleKit.dylib 应含 arm64，实际：\(archs)")
    }
}
