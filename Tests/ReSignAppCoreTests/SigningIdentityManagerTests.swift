import XCTest
@testable import ReSignAppCore
import UDIDRegisterKit

final class SigningIdentityManagerTests: XCTestCase {
    let account = AppleAccount(displayName: "Acme", keyID: "K", issuerID: "I", teamID: "T")
    let cred = ASCCredentials(keyID: "K", issuerID: "I", privateKeyPEM: "PEM")
    func client(_ h: @escaping (String, String) -> HTTPResponse) -> ASCClient {
        ASCClient(http: MockHTTP(h), signJWT: { _ in "T" })
    }

    func testCreateAndStorePersistsCertIdAndUsableKey() async throws {
        let certDER = Data([0x30, 0x01, 0x00])
        let c = client { method, path in
            // createCertificate POST /v1/certificates
            MockHTTP.json(201, ["data": ["id": "CERT9",
                "attributes": ["name": "Dist", "certificateContent": certDER.base64EncodedString()]]])
        }
        let store = InMemorySigningIdentityStore()
        let mgr = SigningIdentityManager(store: store)
        let identity = try await mgr.createAndStore(for: account, cred: cred, client: c)
        XCTAssertEqual(identity.ascCertificateId, "CERT9")
        XCTAssertEqual(identity.certificateDER, certDER)
        XCTAssertFalse(identity.privateKeyDER.isEmpty)
        // 已持久化
        XCTAssertEqual(try store.identity(for: account.id), identity)
        // 私钥可还原并签名
        let key = try SigningKeyCodec.makeRSAPrivateKey(fromDER: identity.privateKeyDER)
        var err: Unmanaged<CFError>?
        XCTAssertNotNil(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data("x".utf8) as CFData, &err))
    }
}
