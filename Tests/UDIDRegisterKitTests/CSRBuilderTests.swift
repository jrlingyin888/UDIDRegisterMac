import XCTest
@testable import UDIDRegisterKit

final class CSRBuilderTests: XCTestCase {
    // 纯结构:外层是 SEQUENCE,且用注入签名闭包时能拼出三段结构
    func testBuildProducesOuterSequence() throws {
        let fakePub: [UInt8] = DER.sequence([DER.integer([0x01, 0x00, 0x01])]) // 占位 RSAPublicKey
        let csr = try CSRBuilder.build(commonName: "cn", countryCode: "US",
                                       rsaPublicKeyDER: fakePub, sign: { _ in [0xAA, 0xBB] })
        XCTAssertEqual(csr.first, 0x30)                 // 外层 SEQUENCE
        XCTAssertFalse(csr.isEmpty)
    }

    // 集成:真实密钥对生成的 CSR,openssl 能验签通过
    func testRealCSRVerifiesWithOpenSSL() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") else {
            throw XCTSkip("no openssl")
        }
        let kp = try SigningKeyPair.generateRSA2048()
        let der = try kp.makeCSR(commonName: "UDIDResign Test", countryCode: "US")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("t.csr")
        try der.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = ["req", "-inform", "DER", "-in", tmp.path, "-noout", "-verify"]
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "openssl 验签应通过")
    }
}
