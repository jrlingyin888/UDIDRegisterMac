import XCTest
@testable import UDIDRegisterKit

final class AccountStoreTests: XCTestCase {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("acct-\(UUID()).json")
    }
    func testAddPersistsAcrossReload() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let s1 = AccountStore(fileURL: url)
        let a = AppleAccount(displayName: "jgz", keyID: "K", issuerID: "I")
        try s1.add(a)
        let s2 = AccountStore(fileURL: url)   // 重新加载
        XCTAssertEqual(s2.accounts.count, 1)
        XCTAssertEqual(s2.accounts[0].displayName, "jgz")
    }
    func testUpdateAndRemove() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let s = AccountStore(fileURL: url)
        var a = AppleAccount(displayName: "old", keyID: "K", issuerID: "I")
        try s.add(a)
        a.displayName = "new"; try s.update(a)
        XCTAssertEqual(s.accounts[0].displayName, "new")
        try s.remove(id: a.id)
        XCTAssertTrue(s.accounts.isEmpty)
    }
}
