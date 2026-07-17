import XCTest
@testable import ReSignAppCore
import UDIDRegisterKit

@MainActor
final class ReSignModelTests: XCTestCase {
    func makeModel(client: ASCClient) throws -> (ReSignModel, InMemorySigningIdentityStore) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("acc-\(UUID().uuidString).json")
        let idStore = InMemorySigningIdentityStore()
        let m = ReSignModel(store: AccountStore(fileURL: tmp),
                            secrets: InMemorySecretStore(),
                            identity: SigningIdentityManager(store: idStore),
                            client: client)
        return (m, idStore)
    }

    func testIdentityStatusReflectsStore() throws {
        let (m, idStore) = try makeModel(client: ASCClient(http: MockHTTP { _, _ in MockHTTP.json(200, ["data": []]) }, signJWT: { _ in "T" }))
        let acc = AppleAccount(displayName: "A", keyID: "K", issuerID: "I")
        XCTAssertEqual(m.identityStatus(for: acc.id), .notCreated)
        try idStore.save(SigningIdentity(privateKeyDER: Data([1]), certificateDER: Data([2]), ascCertificateId: "C"), for: acc.id)
        XCTAssertEqual(m.identityStatus(for: acc.id), .ready)
    }
}
