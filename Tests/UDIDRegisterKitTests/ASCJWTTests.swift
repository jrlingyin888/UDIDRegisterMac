import XCTest
import CryptoKit
@testable import UDIDRegisterKit

final class ASCJWTTests: XCTestCase {
    func testProducesVerifiableES256WithBackdatedIat() throws {
        let key = P256.Signing.PrivateKey()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let jwt = try ASCJWT.sign(keyID: "KID", issuerID: "ISS",
                                  privateKeyPEM: key.pemRepresentation, now: now)
        let parts = jwt.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)

        let claims = try JSONSerialization.jsonObject(
            with: Data(base64URLEncoded: parts[1])!) as! [String: Any]
        XCTAssertEqual(claims["iss"] as? String, "ISS")
        XCTAssertEqual(claims["aud"] as? String, "appstoreconnect-v1")
        XCTAssertEqual(claims["iat"] as? Int, 1_000_000 - 30)
        XCTAssertEqual(claims["exp"] as? Int, 1_000_000 + 1100)

        let sigData = Data(base64URLEncoded: parts[2])!
        XCTAssertEqual(sigData.count, 64)
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: sigData)
        let signingInput = Data((parts[0] + "." + parts[1]).utf8)
        XCTAssertTrue(key.publicKey.isValidSignature(sig, for: signingInput))
    }
    func testInvalidKeyThrows() {
        XCTAssertThrowsError(try ASCJWT.sign(keyID: "K", issuerID: "I", privateKeyPEM: "nope"))
    }
}
