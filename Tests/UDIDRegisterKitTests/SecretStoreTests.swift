import XCTest
@testable import UDIDRegisterKit

final class SecretStoreTests: XCTestCase {
    func testInMemoryRoundTrip() throws {
        let s = InMemorySecretStore()
        let id = UUID()
        XCTAssertNil(try s.load(for: id))
        try s.save("PEMDATA", for: id)
        XCTAssertEqual(try s.load(for: id), "PEMDATA")
        try s.delete(for: id)
        XCTAssertNil(try s.load(for: id))
    }
}
