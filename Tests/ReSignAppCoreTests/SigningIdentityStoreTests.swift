import XCTest
import Security
@testable import ReSignAppCore
import UDIDRegisterKit

final class SigningIdentityStoreTests: XCTestCase {
    func testSaveLoadRemoveRoundTrip() throws {
        let store = KeychainSigningIdentityStore(service: "com.pangu.ReSignMac.test.\(UUID().uuidString)")
        let id = UUID()
        XCTAssertNil(try store.identity(for: id))
        let identity = SigningIdentity(privateKeyDER: Data([0x01, 0x02]),
                                       certificateDER: Data([0x03, 0x04]), ascCertificateId: "CERT1")
        try store.save(identity, for: id)
        XCTAssertEqual(try store.identity(for: id), identity)
        try store.remove(for: id)
        XCTAssertNil(try store.identity(for: id))
    }

    func testSecKeyReconstructionCanSign() throws {
        // 用真实密钥对：导出私钥 DER → 还原 SecKey → 能签名
        let kp = try SigningKeyPair.generateRSA2048()
        let der = try SigningKeyCodec.privateKeyDER(kp.privateKey)
        let restored = try SigningKeyCodec.makeRSAPrivateKey(fromDER: der)
        var err: Unmanaged<CFError>?
        let sig = SecKeyCreateSignature(restored, .rsaSignatureMessagePKCS1v15SHA256,
                                        Data("hi".utf8) as CFData, &err)
        XCTAssertNotNil(sig, "还原出的私钥应能签名")
    }

    func testInMemoryStoreRoundTrip() throws {
        let store = InMemorySigningIdentityStore()
        let id = UUID()
        let identity = SigningIdentity(privateKeyDER: Data([9]), certificateDER: Data([8]), ascCertificateId: "C")
        try store.save(identity, for: id)
        XCTAssertEqual(try store.identity(for: id), identity)
    }
}
