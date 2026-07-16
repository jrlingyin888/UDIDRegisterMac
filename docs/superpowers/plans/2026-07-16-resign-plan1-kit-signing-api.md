# ReSign 计划 1/4：Kit 证书/描述文件 API + CSR 生成 —— Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 `UDIDRegisterKit` 增加「用同一套 `.p8` 创建发布证书、Ad Hoc 描述文件、Bundle ID」的能力，以及本机生成密钥对 + 手写 PKCS#10 CSR，全部纯 Swift、可单测。

**Architecture:** 三块新代码——(a) 极简 DER 编码器 `DER`；(b) `CSRBuilder` + `SigningKeyPair`（Security 框架生成 RSA-2048、导出公钥、SHA256withRSA 签名、组装 CSR）；(c) `ASCClient` 扩展新增 bundleIds / certificates / profiles 端点及高层 `refreshAdHocProfile`。沿用现有 `HTTPClient` 注入 + `MockHTTP` 单测模式；CSR 用 `openssl` 做集成校验。

**Tech Stack:** Swift 5.9 / macOS 14 / Foundation / Security / CryptoKit（已用）；测试 XCTest；集成测试调用系统 `/usr/bin/openssl`（LibreSSL）。

## Global Constraints

- 平台：macOS 14+，Swift 5.9（`Package.swift` 已锁）。
- `UDIDRegisterKit` **不新增任何外部依赖**，保持纯 Foundation/Security/CryptoKit，可离线单测。
- ASC base URL 复用 `ASCClient.base`（`https://api.appstoreconnect.apple.com`）。
- 证书类型 v1 只用 `DISTRIBUTION`；描述文件类型只用 `IOS_APP_ADHOC`（枚举里可留 `DEVELOPMENT` 值但本计划不走）。
- 所有新公开方法命名沿用现有风格：`func xxx(credentials c: ASCCredentials, ...) async throws`。
- 错误统一走现有 `ASCError.http(Int, String)`。

---

### Task 1: DER 极简编码器

**Files:**
- Create: `Sources/UDIDRegisterKit/DER.swift`
- Test: `Tests/UDIDRegisterKitTests/DERTests.swift`

**Interfaces:**
- Consumes: 无。
- Produces:
  - `enum DER`，公开静态方法：
    - `static func length(_ n: Int) -> [UInt8]`
    - `static func sequence(_ items: [[UInt8]]) -> [UInt8]`
    - `static func set(_ items: [[UInt8]]) -> [UInt8]`
    - `static func integer(_ value: [UInt8]) -> [UInt8]`
    - `static func oid(_ bytes: [UInt8]) -> [UInt8]`
    - `static func null() -> [UInt8]`
    - `static func bitString(_ bytes: [UInt8]) -> [UInt8]`
    - `static func utf8String(_ s: String) -> [UInt8]`
    - `static func printableString(_ s: String) -> [UInt8]`
    - `static func contextConstructed(_ tagNumber: UInt8, _ value: [UInt8]) -> [UInt8]`

- [ ] **Step 1: 写失败测试**

```swift
// Tests/UDIDRegisterKitTests/DERTests.swift
import XCTest
@testable import UDIDRegisterKit

final class DERTests: XCTestCase {
    func testLengthShortForm() {
        XCTAssertEqual(DER.length(0), [0x00])
        XCTAssertEqual(DER.length(127), [0x7f])
    }
    func testLengthLongForm() {
        XCTAssertEqual(DER.length(128), [0x81, 0x80])
        XCTAssertEqual(DER.length(200), [0x81, 0xc8])
        XCTAssertEqual(DER.length(256), [0x82, 0x01, 0x00])
    }
    func testIntegerZeroAndHighBit() {
        XCTAssertEqual(DER.integer([0x00]), [0x02, 0x01, 0x00])
        // 最高位为 1 需前置 0x00 防止被读成负数
        XCTAssertEqual(DER.integer([0x80]), [0x02, 0x02, 0x00, 0x80])
    }
    func testOIDandSequence() {
        XCTAssertEqual(DER.oid([0x55, 0x04, 0x03]), [0x06, 0x03, 0x55, 0x04, 0x03])
        XCTAssertEqual(DER.sequence([DER.integer([0x00])]), [0x30, 0x03, 0x02, 0x01, 0x00])
    }
    func testBitStringPrependsUnusedBitCount() {
        XCTAssertEqual(DER.bitString([0xAB]), [0x03, 0x02, 0x00, 0xAB])
    }
    func testContextConstructedEmpty() {
        XCTAssertEqual(DER.contextConstructed(0, []), [0xA0, 0x00])
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter DERTests`
Expected: 编译失败 / `DER` 未定义。

- [ ] **Step 3: 实现 DER 编码器**

```swift
// Sources/UDIDRegisterKit/DER.swift
import Foundation

/// 极简 DER 编码器：只覆盖构造 PKCS#10 CSR 所需的类型。
public enum DER {
    /// DER 长度字段（短式 <128 一字节，否则长式）
    public static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
        return [UInt8(0x80 | bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ value: [UInt8]) -> [UInt8] {
        [tag] + length(value.count) + value
    }

    public static func sequence(_ items: [[UInt8]]) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    public static func set(_ items: [[UInt8]]) -> [UInt8] { tlv(0x31, items.flatMap { $0 }) }

    public static func integer(_ value: [UInt8]) -> [UInt8] {
        var v = value.isEmpty ? [0x00] : value
        if let first = v.first, first & 0x80 != 0 { v = [0x00] + v }  // 防负数误读
        return tlv(0x02, v)
    }

    public static func oid(_ bytes: [UInt8]) -> [UInt8] { tlv(0x06, bytes) }
    public static func null() -> [UInt8] { [0x05, 0x00] }
    public static func bitString(_ bytes: [UInt8]) -> [UInt8] { tlv(0x03, [0x00] + bytes) }
    public static func utf8String(_ s: String) -> [UInt8] { tlv(0x0C, Array(s.utf8)) }
    public static func printableString(_ s: String) -> [UInt8] { tlv(0x13, Array(s.utf8)) }

    /// [tagNumber] 上下文构造标签（如 CSR 的 attributes [0]）
    public static func contextConstructed(_ tagNumber: UInt8, _ value: [UInt8]) -> [UInt8] {
        tlv(0xA0 | tagNumber, value)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter DERTests`
Expected: PASS（6 个用例全绿）。

- [ ] **Step 5: 提交**

```bash
git add Sources/UDIDRegisterKit/DER.swift Tests/UDIDRegisterKitTests/DERTests.swift
git commit -m "feat(kit): minimal DER encoder for CSR"
```

---

### Task 2: SigningKeyPair + CSRBuilder（本机密钥对 + PKCS#10 CSR）

**Files:**
- Create: `Sources/UDIDRegisterKit/CSRBuilder.swift`
- Create: `Sources/UDIDRegisterKit/SigningKeyPair.swift`
- Test: `Tests/UDIDRegisterKitTests/CSRBuilderTests.swift`

**Interfaces:**
- Consumes: `DER`（Task 1）。
- Produces:
  - `enum CSRError: Error { case keyGeneration; case signing; case publicKeyExport }`
  - `struct CSRBuilder`：
    - `static func build(commonName: String, countryCode: String, rsaPublicKeyDER: [UInt8], sign: ([UInt8]) throws -> [UInt8]) rethrows -> Data`
  - `struct SigningKeyPair`：
    - `let privateKey: SecKey`，`let publicKey: SecKey`
    - `static func generateRSA2048() throws -> SigningKeyPair`
    - `func publicKeyDER() throws -> [UInt8]`（PKCS#1 RSAPublicKey）
    - `func signSHA256(_ message: [UInt8]) throws -> [UInt8]`
    - `func makeCSR(commonName: String, countryCode: String) throws -> Data`

- [ ] **Step 1: 写失败测试**（结构断言 + openssl 集成校验）

```swift
// Tests/UDIDRegisterKitTests/CSRBuilderTests.swift
import XCTest
@testable import UDIDRegisterKit

final class CSRBuilderTests: XCTestCase {
    // 纯结构：外层是 SEQUENCE，且用注入签名闭包时能拼出三段结构
    func testBuildProducesOuterSequence() throws {
        let fakePub: [UInt8] = DER.sequence([DER.integer([0x01, 0x00, 0x01])]) // 占位 RSAPublicKey
        let csr = try CSRBuilder.build(commonName: "cn", countryCode: "US",
                                       rsaPublicKeyDER: fakePub, sign: { _ in [0xAA, 0xBB] })
        XCTAssertEqual(csr.first, 0x30)                 // 外层 SEQUENCE
        XCTAssertFalse(csr.isEmpty)
    }

    // 集成：真实密钥对生成的 CSR，openssl 能验签通过
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
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter CSRBuilderTests`
Expected: 编译失败 / `CSRBuilder`、`SigningKeyPair` 未定义。

- [ ] **Step 3: 实现 CSRBuilder**

```swift
// Sources/UDIDRegisterKit/CSRBuilder.swift
import Foundation

public enum CSRError: Error { case keyGeneration; case signing; case publicKeyExport }

/// 用注入的签名闭包构造 PKCS#10 CSR（DER）。签名闭包对 certificationRequestInfo 的 DER 做 SHA256withRSA。
public struct CSRBuilder {
    static let oidCN: [UInt8] = [0x55, 0x04, 0x03]                                        // 2.5.4.3
    static let oidC:  [UInt8] = [0x55, 0x04, 0x06]                                        // 2.5.4.6
    static let oidRSAEncryption: [UInt8] = [0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01] // 1.2.840.113549.1.1.1
    static let oidSHA256RSA:     [UInt8] = [0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x0b] // 1.2.840.113549.1.1.11

    /// - rsaPublicKeyDER: PKCS#1 RSAPublicKey DER（SecKeyCopyExternalRepresentation 输出）
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
```

- [ ] **Step 4: 实现 SigningKeyPair**

```swift
// Sources/UDIDRegisterKit/SigningKeyPair.swift
import Foundation
import Security

/// 本机 RSA-2048 密钥对：生成、导出公钥、SHA256withRSA 签名、拼 CSR。私钥不出机。
public struct SigningKeyPair {
    public let privateKey: SecKey
    public let publicKey: SecKey

    public init(privateKey: SecKey, publicKey: SecKey) {
        self.privateKey = privateKey; self.publicKey = publicKey
    }

    public static func generateRSA2048() throws -> SigningKeyPair {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048
        ]
        var err: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &err) else {
            throw CSRError.keyGeneration
        }
        guard let pub = SecKeyCopyPublicKey(priv) else { throw CSRError.publicKeyExport }
        return SigningKeyPair(privateKey: priv, publicKey: pub)
    }

    /// PKCS#1 RSAPublicKey DER
    public func publicKeyDER() throws -> [UInt8] {
        var err: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(publicKey, &err) as Data? else {
            throw CSRError.publicKeyExport
        }
        return Array(data)
    }

    /// SHA256withRSA-PKCS1v15 签名
    public func signSHA256(_ message: [UInt8]) throws -> [UInt8] {
        var err: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(privateKey,
                .rsaSignatureMessagePKCS1v15SHA256,
                Data(message) as CFData, &err) as Data? else {
            throw CSRError.signing
        }
        return Array(sig)
    }

    public func makeCSR(commonName: String, countryCode: String = "US") throws -> Data {
        try CSRBuilder.build(commonName: commonName, countryCode: countryCode,
                             rsaPublicKeyDER: publicKeyDER(), sign: signSHA256)
    }
}
```

- [ ] **Step 5: 运行确认通过**

Run: `swift test --filter CSRBuilderTests`
Expected: PASS（`testRealCSRVerifiesWithOpenSSL` 看到 openssl 退出码 0）。

- [ ] **Step 6: 提交**

```bash
git add Sources/UDIDRegisterKit/CSRBuilder.swift Sources/UDIDRegisterKit/SigningKeyPair.swift Tests/UDIDRegisterKitTests/CSRBuilderTests.swift
git commit -m "feat(kit): RSA keypair + PKCS#10 CSR builder"
```

---

### Task 3: 签名相关 Models + 让 ASCClient.headers 可扩展

**Files:**
- Create: `Sources/UDIDRegisterKit/SigningModels.swift`
- Modify: `Sources/UDIDRegisterKit/ASCClient.swift`（把 `private func headers` 改为 internal，供扩展文件调用）
- Test: `Tests/UDIDRegisterKitTests/SigningModelsTests.swift`

**Interfaces:**
- Consumes: 无。
- Produces:
  - `enum CertificateType: String { case distribution = "DISTRIBUTION"; case development = "DEVELOPMENT" }`
  - `enum ProfileType: String { case iosAppAdHoc = "IOS_APP_ADHOC" }`
  - `struct BundleIdInfo: Hashable { let id, identifier, name: String; init?(json:) }`
  - `struct CertificateInfo: Hashable { let id, name: String; let contentDER: Data; let expirationDate, serialNumber: String?; init?(json:) }`
  - `struct ProfileInfo: Hashable { let id, name: String; let uuid: String?; let contentData: Data; init?(json:) }`
  - `ASCClient.headers(_:)` 变为 internal（Task 4/5/6 的扩展依赖它）。

- [ ] **Step 1: 写失败测试**

```swift
// Tests/UDIDRegisterKitTests/SigningModelsTests.swift
import XCTest
@testable import UDIDRegisterKit

final class SigningModelsTests: XCTestCase {
    func testBundleIdInfoParsesOrNil() {
        let ok = BundleIdInfo(json: ["id": "B1", "attributes": ["identifier": "com.a.b", "name": "AB"]])
        XCTAssertEqual(ok?.id, "B1")
        XCTAssertEqual(ok?.identifier, "com.a.b")
        XCTAssertNil(BundleIdInfo(json: ["id": "B1"]))  // 缺 attributes → nil
    }
    func testCertificateInfoDecodesBase64Content() {
        let der = Data([0x30, 0x01, 0x00])
        let info = CertificateInfo(json: ["id": "C1",
            "attributes": ["name": "Dist", "certificateContent": der.base64EncodedString()]])
        XCTAssertEqual(info?.contentDER, der)
    }
    func testProfileInfoDecodesContentAndUUID() {
        let der = Data([0x01, 0x02, 0x03])
        let info = ProfileInfo(json: ["id": "P1",
            "attributes": ["name": "AdHoc", "uuid": "U-1", "profileContent": der.base64EncodedString()]])
        XCTAssertEqual(info?.uuid, "U-1")
        XCTAssertEqual(info?.contentData, der)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter SigningModelsTests`
Expected: 编译失败 / 三个类型未定义。

- [ ] **Step 3: 实现 Models**

```swift
// Sources/UDIDRegisterKit/SigningModels.swift
import Foundation

public enum CertificateType: String { case distribution = "DISTRIBUTION"; case development = "DEVELOPMENT" }
public enum ProfileType: String { case iosAppAdHoc = "IOS_APP_ADHOC" }

public struct BundleIdInfo: Hashable {
    public let id: String
    public let identifier: String
    public let name: String
    public init(id: String, identifier: String, name: String) {
        self.id = id; self.identifier = identifier; self.name = name
    }
    public init?(json d: [String: Any]) {
        guard let id = d["id"] as? String, let a = d["attributes"] as? [String: Any],
              let identifier = a["identifier"] as? String else { return nil }
        self.init(id: id, identifier: identifier, name: (a["name"] as? String) ?? identifier)
    }
}

public struct CertificateInfo: Hashable {
    public let id: String
    public let name: String
    public let contentDER: Data
    public let expirationDate: String?
    public let serialNumber: String?
    public init(id: String, name: String, contentDER: Data, expirationDate: String?, serialNumber: String?) {
        self.id = id; self.name = name; self.contentDER = contentDER
        self.expirationDate = expirationDate; self.serialNumber = serialNumber
    }
    public init?(json d: [String: Any]) {
        guard let id = d["id"] as? String, let a = d["attributes"] as? [String: Any] else { return nil }
        let content = (a["certificateContent"] as? String)
            .flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) } ?? Data()
        self.init(id: id, name: (a["name"] as? String) ?? "", contentDER: content,
                  expirationDate: a["expirationDate"] as? String, serialNumber: a["serialNumber"] as? String)
    }
}

public struct ProfileInfo: Hashable {
    public let id: String
    public let name: String
    public let uuid: String?
    public let contentData: Data
    public init(id: String, name: String, uuid: String?, contentData: Data) {
        self.id = id; self.name = name; self.uuid = uuid; self.contentData = contentData
    }
    public init?(json d: [String: Any]) {
        guard let id = d["id"] as? String, let a = d["attributes"] as? [String: Any] else { return nil }
        let content = (a["profileContent"] as? String)
            .flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) } ?? Data()
        self.init(id: id, name: (a["name"] as? String) ?? "", uuid: a["uuid"] as? String, contentData: content)
    }
}
```

- [ ] **Step 4: 让 headers 可被扩展调用**

在 `Sources/UDIDRegisterKit/ASCClient.swift` 把
```swift
    private func headers(_ c: ASCCredentials) throws -> [String: String] {
```
改为（去掉 `private`）：
```swift
    func headers(_ c: ASCCredentials) throws -> [String: String] {
```

- [ ] **Step 5: 运行确认通过**

Run: `swift test --filter SigningModelsTests`
Expected: PASS。且 `swift build` 通过（headers 改 internal 不破坏现有代码）。

- [ ] **Step 6: 提交**

```bash
git add Sources/UDIDRegisterKit/SigningModels.swift Sources/UDIDRegisterKit/ASCClient.swift Tests/UDIDRegisterKitTests/SigningModelsTests.swift
git commit -m "feat(kit): models for bundleIds/certificates/profiles"
```

---

### Task 4: ASCClient — Bundle IDs 端点

**Files:**
- Create: `Sources/UDIDRegisterKit/ASCClient+Signing.swift`
- Test: `Tests/UDIDRegisterKitTests/ASCSigningClientTests.swift`

**Interfaces:**
- Consumes: `BundleIdInfo`（Task 3）、`ASCClient.headers`（Task 3）、`ASCError`、`HTTPResponse`。
- Produces（本 Task 部分，其余方法在 Task 5/6 追加到同一扩展文件）：
  - `func listBundleIds(credentials c: ASCCredentials, identifier: String) async throws -> [BundleIdInfo]`
  - `func createBundleId(credentials c: ASCCredentials, identifier: String, name: String) async throws -> BundleIdInfo`
  - `func findOrCreateBundleId(credentials c: ASCCredentials, identifier: String, name: String) async throws -> BundleIdInfo`
  - 内部：`static func ensureOK(_ resp: HTTPResponse) throws`、`static func pemCSR(_ der: Data) -> String`

- [ ] **Step 1: 写失败测试**

```swift
// Tests/UDIDRegisterKitTests/ASCSigningClientTests.swift
import XCTest
@testable import UDIDRegisterKit

final class ASCSigningClientTests: XCTestCase {
    let cred = ASCCredentials(keyID: "K", issuerID: "I", privateKeyPEM: "PEM")
    func makeClient(_ h: @escaping (String, String) -> HTTPResponse) -> ASCClient {
        ASCClient(http: MockHTTP(h), signJWT: { _ in "TESTTOKEN" })
    }

    func testFindOrCreateBundleIdReturnsExisting() async throws {
        let c = makeClient { method, path in
            XCTAssertEqual(method, "GET")
            return MockHTTP.json(200, ["data": [["id": "B9",
                "attributes": ["identifier": "com.a.b", "name": "AB"]]]])
        }
        let info = try await c.findOrCreateBundleId(credentials: cred, identifier: "com.a.b", name: "AB")
        XCTAssertEqual(info.id, "B9")
    }
    func testFindOrCreateBundleIdCreatesWhenMissing() async throws {
        let c = makeClient { method, _ in
            if method == "GET" { return MockHTTP.json(200, ["data": []]) }
            return MockHTTP.json(201, ["data": ["id": "Bnew",
                "attributes": ["identifier": "com.a.b", "name": "AB"]]])
        }
        let info = try await c.findOrCreateBundleId(credentials: cred, identifier: "com.a.b", name: "AB")
        XCTAssertEqual(info.id, "Bnew")
    }
    func testCreateBundleIdPropagatesError() async throws {
        let c = makeClient { _, _ in MockHTTP.json(409, ["errors": [["detail": "重复"]]]) }
        do { _ = try await c.createBundleId(credentials: cred, identifier: "x", name: "x"); XCTFail() }
        catch let ASCError.http(status, detail) { XCTAssertEqual(status, 409); XCTAssertEqual(detail, "重复") }
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter ASCSigningClientTests`
Expected: 编译失败 / 方法未定义。

- [ ] **Step 3: 实现扩展（bundleIds + 公共 helper）**

```swift
// Sources/UDIDRegisterKit/ASCClient+Signing.swift
import Foundation

extension ASCClient {
    // MARK: - Bundle IDs
    public func listBundleIds(credentials c: ASCCredentials, identifier: String) async throws -> [BundleIdInfo] {
        var comp = URLComponents(url: Self.base.appendingPathComponent("v1/bundleIds"), resolvingAgainstBaseURL: false)!
        comp.queryItems = [URLQueryItem(name: "filter[identifier]", value: identifier),
                           URLQueryItem(name: "limit", value: "200")]
        let resp = try await http.send(method: "GET", url: comp.url!, headers: try headers(c), body: nil)
        try Self.ensureOK(resp)
        let arr = (Self.jsonObject(resp)?["data"] as? [[String: Any]]) ?? []
        return arr.compactMap(BundleIdInfo.init(json:))
    }

    public func createBundleId(credentials c: ASCCredentials, identifier: String, name: String) async throws -> BundleIdInfo {
        let payload: [String: Any] = ["data": ["type": "bundleIds",
            "attributes": ["identifier": identifier, "name": name, "platform": "IOS"]]]
        let resp = try await http.send(method: "POST",
            url: Self.base.appendingPathComponent("v1/bundleIds"),
            headers: try headers(c), body: try JSONSerialization.data(withJSONObject: payload))
        try Self.ensureOK(resp)
        guard let d = Self.jsonObject(resp)?["data"] as? [String: Any], let info = BundleIdInfo(json: d) else {
            throw ASCError.http(resp.status, "创建 Bundle ID 返回异常")
        }
        return info
    }

    public func findOrCreateBundleId(credentials c: ASCCredentials, identifier: String, name: String) async throws -> BundleIdInfo {
        if let existing = try await listBundleIds(credentials: c, identifier: identifier).first { return existing }
        return try await createBundleId(credentials: c, identifier: identifier, name: name)
    }

    // MARK: - Helpers
    static func ensureOK(_ resp: HTTPResponse) throws {
        guard (200...299).contains(resp.status) else {
            let detail = ((jsonObject(resp)?["errors"] as? [[String: Any]])?.first?["detail"] as? String) ?? ""
            throw ASCError.http(resp.status, detail)
        }
    }
    static func jsonObject(_ resp: HTTPResponse) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any]
    }
    static func pemCSR(_ der: Data) -> String {
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE REQUEST-----\n\(b64)\n-----END CERTIFICATE REQUEST-----\n"
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter ASCSigningClientTests`
Expected: PASS（3 个用例）。

- [ ] **Step 5: 提交**

```bash
git add Sources/UDIDRegisterKit/ASCClient+Signing.swift Tests/UDIDRegisterKitTests/ASCSigningClientTests.swift
git commit -m "feat(kit): ASC bundleIds endpoints"
```

---

### Task 5: ASCClient — Certificates 端点

**Files:**
- Modify: `Sources/UDIDRegisterKit/ASCClient+Signing.swift`（追加 certificates 方法）
- Modify: `Tests/UDIDRegisterKitTests/ASCSigningClientTests.swift`（追加用例）

**Interfaces:**
- Consumes: `CertificateInfo`、`CertificateType`（Task 3）、`Self.pemCSR` / `Self.ensureOK` / `Self.jsonObject`（Task 4）。
- Produces:
  - `func listCertificates(credentials c: ASCCredentials, type: CertificateType) async throws -> [CertificateInfo]`
  - `func createCertificate(credentials c: ASCCredentials, csrDER: Data, type: CertificateType) async throws -> CertificateInfo`

- [ ] **Step 1: 追加失败测试**

```swift
// 追加到 ASCSigningClientTests
    func testCreateCertificateSendsPEMandParsesContent() async throws {
        let der = Data([0x30, 0x01, 0x00])
        let c = makeClient { method, path in
            XCTAssertEqual(method, "POST")
            XCTAssertTrue(path.hasSuffix("v1/certificates"))
            return MockHTTP.json(201, ["data": ["id": "C1",
                "attributes": ["name": "Dist", "certificateContent": der.base64EncodedString()]]])
        }
        let info = try await c.createCertificate(credentials: cred,
                                                 csrDER: Data([0xDE, 0xAD]), type: .distribution)
        XCTAssertEqual(info.id, "C1")
        XCTAssertEqual(info.contentDER, der)
    }
    func testPemCSRWrapsHeaderFooter() {
        let pem = ASCClient.pemCSR(Data([0x00, 0x01]))
        XCTAssertTrue(pem.hasPrefix("-----BEGIN CERTIFICATE REQUEST-----"))
        XCTAssertTrue(pem.contains("-----END CERTIFICATE REQUEST-----"))
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter ASCSigningClientTests`
Expected: 编译失败 / `createCertificate` 未定义。

- [ ] **Step 3: 追加实现**（加到 `ASCClient+Signing.swift` 的 extension 内，`// MARK: - Bundle IDs` 段之后）

```swift
    // MARK: - Certificates
    public func listCertificates(credentials c: ASCCredentials, type: CertificateType) async throws -> [CertificateInfo] {
        var comp = URLComponents(url: Self.base.appendingPathComponent("v1/certificates"), resolvingAgainstBaseURL: false)!
        comp.queryItems = [URLQueryItem(name: "filter[certificateType]", value: type.rawValue),
                           URLQueryItem(name: "limit", value: "200")]
        let resp = try await http.send(method: "GET", url: comp.url!, headers: try headers(c), body: nil)
        try Self.ensureOK(resp)
        let arr = (Self.jsonObject(resp)?["data"] as? [[String: Any]]) ?? []
        return arr.compactMap(CertificateInfo.init(json:))
    }

    public func createCertificate(credentials c: ASCCredentials, csrDER: Data, type: CertificateType) async throws -> CertificateInfo {
        let payload: [String: Any] = ["data": ["type": "certificates",
            "attributes": ["certificateType": type.rawValue, "csrContent": Self.pemCSR(csrDER)]]]
        let resp = try await http.send(method: "POST",
            url: Self.base.appendingPathComponent("v1/certificates"),
            headers: try headers(c), body: try JSONSerialization.data(withJSONObject: payload))
        try Self.ensureOK(resp)
        guard let d = Self.jsonObject(resp)?["data"] as? [String: Any], let info = CertificateInfo(json: d) else {
            throw ASCError.http(resp.status, "创建证书返回异常")
        }
        return info
    }
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter ASCSigningClientTests`
Expected: PASS（新增 2 个用例）。

- [ ] **Step 5: 提交**

```bash
git add Sources/UDIDRegisterKit/ASCClient+Signing.swift Tests/UDIDRegisterKitTests/ASCSigningClientTests.swift
git commit -m "feat(kit): ASC certificates endpoints"
```

---

### Task 6: ASCClient — Profiles 端点 + refreshAdHocProfile

**Files:**
- Modify: `Sources/UDIDRegisterKit/ASCClient+Signing.swift`（追加 profiles 方法）
- Modify: `Tests/UDIDRegisterKitTests/ASCSigningClientTests.swift`（追加用例）

**Interfaces:**
- Consumes: `ProfileInfo`、`ProfileType`（Task 3）、helper（Task 4）。
- Produces:
  - `func listProfiles(credentials c: ASCCredentials, name: String) async throws -> [ProfileInfo]`
  - `func deleteProfile(credentials c: ASCCredentials, id: String) async throws`
  - `func createAdHocProfile(credentials c: ASCCredentials, name: String, bundleIdResourceId: String, certificateId: String, deviceIds: [String]) async throws -> ProfileInfo`
  - `func refreshAdHocProfile(credentials c: ASCCredentials, name: String, bundleIdResourceId: String, certificateId: String, deviceIds: [String]) async throws -> ProfileInfo`（先删同名再建）

- [ ] **Step 1: 追加失败测试**

```swift
// 追加到 ASCSigningClientTests
    func testRefreshDeletesOldThenCreates() async throws {
        // 同步、加锁的记录器（不要用 detached Task，会与断言竞态）
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock(); private var log: [String] = []
            func add(_ s: String) { lock.lock(); log.append(s); lock.unlock() }
            var entries: [String] { lock.lock(); defer { lock.unlock() }; return log }
        }
        let rec = Recorder()
        let der = Data([0x0A, 0x0B])
        let c = ASCClient(http: MockHTTP { method, path in
            rec.add("\(method) \(path)")
            if method == "GET" {  // listProfiles 返回一个旧的同名 profile
                return MockHTTP.json(200, ["data": [["id": "OLD", "attributes": ["name": "n"]]]])
            }
            if method == "DELETE" { return HTTPResponse(status: 204, body: Data()) }
            return MockHTTP.json(201, ["data": ["id": "NEW",
                "attributes": ["name": "n", "uuid": "U", "profileContent": der.base64EncodedString()]]])
        }, signJWT: { _ in "T" })

        let info = try await c.refreshAdHocProfile(credentials: cred, name: "n",
            bundleIdResourceId: "B", certificateId: "C", deviceIds: ["D1", "D2"])
        XCTAssertEqual(info.id, "NEW")
        XCTAssertEqual(info.contentData, der)
        // DELETE 命中旧 profile 路径（同步记录，无竞态）
        XCTAssertTrue(rec.entries.contains { $0.hasPrefix("DELETE") && $0.contains("v1/profiles/OLD") })
    }
    func testCreateAdHocProfileParsesContent() async throws {
        let der = Data([0x77])
        let c = makeClient { _, _ in
            MockHTTP.json(201, ["data": ["id": "P",
                "attributes": ["name": "n", "profileContent": der.base64EncodedString()]]])
        }
        let info = try await c.createAdHocProfile(credentials: cred, name: "n",
            bundleIdResourceId: "B", certificateId: "C", deviceIds: ["D1"])
        XCTAssertEqual(info.contentData, der)
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter ASCSigningClientTests`
Expected: 编译失败 / profiles 方法未定义。

- [ ] **Step 3: 追加实现**（加到 `ASCClient+Signing.swift` 的 extension 内，certificates 段之后）

```swift
    // MARK: - Profiles
    public func listProfiles(credentials c: ASCCredentials, name: String) async throws -> [ProfileInfo] {
        var comp = URLComponents(url: Self.base.appendingPathComponent("v1/profiles"), resolvingAgainstBaseURL: false)!
        comp.queryItems = [URLQueryItem(name: "filter[name]", value: name),
                           URLQueryItem(name: "limit", value: "200")]
        let resp = try await http.send(method: "GET", url: comp.url!, headers: try headers(c), body: nil)
        try Self.ensureOK(resp)
        let arr = (Self.jsonObject(resp)?["data"] as? [[String: Any]]) ?? []
        return arr.compactMap(ProfileInfo.init(json:))
    }

    public func deleteProfile(credentials c: ASCCredentials, id: String) async throws {
        let resp = try await http.send(method: "DELETE",
            url: Self.base.appendingPathComponent("v1/profiles/\(id)"),
            headers: try headers(c), body: nil)
        try Self.ensureOK(resp)
    }

    public func createAdHocProfile(credentials c: ASCCredentials, name: String,
                                   bundleIdResourceId: String, certificateId: String,
                                   deviceIds: [String]) async throws -> ProfileInfo {
        let payload: [String: Any] = ["data": [
            "type": "profiles",
            "attributes": ["name": name, "profileType": ProfileType.iosAppAdHoc.rawValue],
            "relationships": [
                "bundleId": ["data": ["type": "bundleIds", "id": bundleIdResourceId]],
                "certificates": ["data": [["type": "certificates", "id": certificateId]]],
                "devices": ["data": deviceIds.map { ["type": "devices", "id": $0] }]
            ]
        ]]
        let resp = try await http.send(method: "POST",
            url: Self.base.appendingPathComponent("v1/profiles"),
            headers: try headers(c), body: try JSONSerialization.data(withJSONObject: payload))
        try Self.ensureOK(resp)
        guard let d = Self.jsonObject(resp)?["data"] as? [String: Any], let info = ProfileInfo(json: d) else {
            throw ASCError.http(resp.status, "创建描述文件返回异常")
        }
        return info
    }

    /// 删除同名旧 profile 后重建，带上传入的全部设备（加设备后自动纳入新 UDID）。
    public func refreshAdHocProfile(credentials c: ASCCredentials, name: String,
                                    bundleIdResourceId: String, certificateId: String,
                                    deviceIds: [String]) async throws -> ProfileInfo {
        for old in try await listProfiles(credentials: c, name: name) {
            try await deleteProfile(credentials: c, id: old.id)
        }
        return try await createAdHocProfile(credentials: c, name: name,
            bundleIdResourceId: bundleIdResourceId, certificateId: certificateId, deviceIds: deviceIds)
    }
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test`（跑全量，确认没有回归）
Expected: 全绿，包含新增 profiles 用例。

- [ ] **Step 5: 提交**

```bash
git add Sources/UDIDRegisterKit/ASCClient+Signing.swift Tests/UDIDRegisterKitTests/ASCSigningClientTests.swift
git commit -m "feat(kit): ASC profiles endpoints + refreshAdHocProfile"
```

---

## Self-Review

**Spec coverage（对应 spec「三个核心流程/1 证书创建」与「/2 描述文件自动刷新」）：**
- 密钥对生成 + CSR → Task 2 ✅
- 提交 CSR 建证书 / 列证书 → Task 5 ✅
- bundleId 查/建 → Task 4 ✅
- profile 删旧建新带全部设备（`refreshAdHocProfile`）→ Task 6 ✅
- p12 组装 / 临时钥匙串 / codesign / IPA 打包 → **不在本计划**（属计划 3 ReSignKit）。
- 账号共享 → **不在本计划**（属计划 2）。

**Placeholder scan：** 无 TBD/TODO；每个代码步骤含完整代码。

**Type consistency：** `BundleIdInfo/CertificateInfo/ProfileInfo` 在 Task 3 定义，Task 4/5/6 一致引用；helper `ensureOK/jsonObject/pemCSR` 在 Task 4 定义，Task 5/6 复用；`headers` 在 Task 3 改 internal 供 Task 4/5/6 扩展调用。方法签名在各 Task 的 Interfaces 块一致。

**边界说明：** 本计划交付「Kit 能用 `.p8` 建证书/描述文件/BundleId + 本机造 CSR」，可 `swift test` 全量验证，不依赖沙盒/ReSignApp，独立可测。计划 2-4 在本计划实现并验证后再逐一编写，避免提前漂移。
