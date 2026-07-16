import Foundation

public enum CSRError: Error { case keyGeneration; case signing; case publicKeyExport }

/// 用注入的签名闭包构造 PKCS#10 CSR(DER)。签名闭包对 certificationRequestInfo 的 DER 做 SHA256withRSA。
public struct CSRBuilder {
    static let oidCN: [UInt8] = [0x55, 0x04, 0x03]                                        // 2.5.4.3
    static let oidC:  [UInt8] = [0x55, 0x04, 0x06]                                        // 2.5.4.6
    static let oidRSAEncryption: [UInt8] = [0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01] // 1.2.840.113549.1.1.1
    static let oidSHA256RSA:     [UInt8] = [0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x0b] // 1.2.840.113549.1.1.11

    /// - rsaPublicKeyDER: PKCS#1 RSAPublicKey DER(SecKeyCopyExternalRepresentation 输出)
    public static func build(commonName: String, countryCode: String,
                             rsaPublicKeyDER: [UInt8],
                             sign: ([UInt8]) throws -> [UInt8]) rethrows -> Data {
        let cRDN  = DER.set([DER.sequence([DER.oid(oidC),  DER.printableString(countryCode)])])
        let cnRDN = DER.set([DER.sequence([DER.oid(oidCN), DER.utf8String(commonName)])])
        let subject = DER.sequence([cRDN, cnRDN])

        let algId = DER.sequence([DER.oid(oidRSAEncryption), DER.null()])
        let spki  = DER.sequence([algId, DER.bitString(rsaPublicKeyDER)])

        let attributes = DER.contextConstructed(0, [])  // 空 [0] IMPLICIT SET OF

        let cri = DER.sequence([DER.integer([0x00]), subject, spki, attributes])

        let signature = try sign(cri)
        let sigAlg = DER.sequence([DER.oid(oidSHA256RSA), DER.null()])
        return Data(DER.sequence([cri, sigAlg, DER.bitString(signature)]))
    }
}
