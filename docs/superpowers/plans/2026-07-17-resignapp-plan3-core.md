# ReSignApp 计划 3（核心逻辑）—— Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建 ReSignApp 的**可测试核心**：新 `ReSignAppCore` 库（+ 占位 `ReSignApp` 可执行 target），签名身份的持久化/自建/导入，以及「一键重签」流水线的编排模型——全部可 `swift test` 验证，不含 SwiftUI 视图与打包（留计划 4）。

**Architecture:** 逻辑放进新库 `ReSignAppCore`（依赖 `UDIDRegisterKit` + `ReSignKit`），这样测试 target 能 `@testable import`（SwiftPM 不能 import 可执行 target）。`SigningIdentityStore` 纯持久化；`SigningIdentityManager` 用 `ASCClient`+Security 做自建/导入；`ReSignModel` 用**可注入**的 client / manager / 重签器闭包 / bundleId 读取闭包编排流水线，因此不碰真实 codesign/钥匙串即可单测编排与错误分支。`ReSignKit` 加一个 `readBundleIdentifier` peek 助手。

**Tech Stack:** Swift 5.9 / macOS 14 / Foundation / Security / Observation；XCTest；集成测试用系统 `ditto`（peek IPA）。

## Global Constraints

- 平台 macOS 14+，Swift 5.9。
- 逻辑放 `ReSignAppCore` 库（可测），视图/@main 放 `ReSignApp` 可执行（计划 4）。不新增第三方依赖。
- ReSignApp 有**自己的 bundle id** `com.pangu.ReSignMac`（用作其账号钥匙串/签名钥匙串 service），与注册 app 的 `AppIdentifiers.bundleID`（`com.pangu.UDIDRegisterMac`）分开。
- 签名身份 = `{ privateKeyDER: Data, certificateDER: Data, ascCertificateId: String }`；发布证书**一个账号建一次、长期复用**。
- entitlements 由描述文件派生（ReSignKit 已保证）；含扩展/Watch/App Clips 的 app 明确报错（ReSignKit 已内建 `unsupportedNestedBundle`）。
- 错误统一走 `ASCError` / `ReSignError` / `AppError`，面向用户文案走 `UserFacingMessage`。
- 本计划**不含**：SwiftUI 视图、@main app、打包、`exportP12`（导出 p12 属计划 4 便捷功能）。

---

### Task 1: 新增 ReSignAppCore / ReSignApp target + bundle id 常量

**Files:**
- Modify: `Package.swift`
- Create: `Sources/ReSignAppCore/ReSignAppIdentifiers.swift`
- Create: `Sources/ReSignApp/main.swift`（占位可执行，计划 4 换成 SwiftUI @main）
- Test: `Tests/ReSignAppCoreTests/ReSignAppIdentifiersTests.swift`

**Interfaces:**
- Consumes: 无。
- Produces:
  - Package 新增：库 `ReSignAppCore`（依赖 `UDIDRegisterKit` + `ReSignKit`）、测试 `ReSignAppCoreTests`、可执行 `ReSignApp`（依赖 `ReSignAppCore`）。
  - `enum ReSignAppIdentifiers { static let bundleID = "com.pangu.ReSignMac" }`

- [ ] **Step 1: 写失败测试**

```swift
// Tests/ReSignAppCoreTests/ReSignAppIdentifiersTests.swift
import XCTest
@testable import ReSignAppCore
import UDIDRegisterKit

final class ReSignAppIdentifiersTests: XCTestCase {
    func testBundleIDValueAndDistinctFromRegisterApp() {
        XCTAssertEqual(ReSignAppIdentifiers.bundleID, "com.pangu.ReSignMac")
        XCTAssertNotEqual(ReSignAppIdentifiers.bundleID, AppIdentifiers.bundleID)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter ReSignAppIdentifiersTests`
Expected: 编译失败（`ReSignAppCore` 模块不存在）。

- [ ] **Step 3: Package.swift 增加 target**

在 `targets:` 数组末尾（`ReSignKitTests` 之后）加入：

```swift
        .target(name: "ReSignAppCore", dependencies: ["UDIDRegisterKit", "ReSignKit"]),
        .testTarget(name: "ReSignAppCoreTests", dependencies: ["ReSignAppCore"]),
        .executableTarget(name: "ReSignApp", dependencies: ["ReSignAppCore"]),
```

- [ ] **Step 4: 实现常量 + 占位 main**

```swift
// Sources/ReSignAppCore/ReSignAppIdentifiers.swift
import Foundation

/// ReSignApp 全局标识符。与注册 app 分开（各自独立的钥匙串 service）。
/// 打包脚本(计划4)会从本文件抽 bundleID 写入 Info.plist。
public enum ReSignAppIdentifiers {
    public static let bundleID = "com.pangu.ReSignMac"
}
```

```swift
// Sources/ReSignApp/main.swift
// 占位：计划 4 用 SwiftUI @main 替换。当前仅保证可执行 target 能编译。
import ReSignAppCore
print("ReSignApp \(ReSignAppIdentifiers.bundleID)")
```

- [ ] **Step 5: 运行确认通过**

Run: `swift test --filter ReSignAppIdentifiersTests` → PASS；`swift build` 全部 target 通过。

- [ ] **Step 6: 提交**

```bash
git add Package.swift Sources/ReSignAppCore/ReSignAppIdentifiers.swift Sources/ReSignApp/main.swift Tests/ReSignAppCoreTests/ReSignAppIdentifiersTests.swift
git commit -m "feat(resignapp): scaffold ReSignAppCore + ReSignApp targets"
```

---

### Task 2: ReSignKit —— readBundleIdentifier（重签前 peek bundle id）

**Files:**
- Modify: `Sources/ReSignKit/IPAResigner.swift`
- Test: `Tests/ReSignKitTests/IPAResignerTests.swift`（追加）

**Interfaces:**
- Consumes: `Subprocess`、`AppBundle`、`ReSignError`、`findPayloadApp`（均已在 ReSignKit）。
- Produces:
  - `static func readBundleIdentifier(ipaURL: URL) throws -> String`（解包读 `Payload/*.app/Info.plist` 的 `CFBundleIdentifier`；无 app 抛 `ReSignError.appNotFound`）

- [ ] **Step 1: 追加失败测试**

```swift
// 追加到 Tests/ReSignKitTests/IPAResignerTests.swift 的 IPAResignerTests 类
    func testReadBundleIdentifierFromIPA() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ditto") else { throw XCTSkip("no ditto") }
        let tmp = try TestTemp.dir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let payload = tmp.appendingPathComponent("Payload")
        let app = payload.appendingPathComponent("Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "com.demo.peek", "CFBundleExecutable": "Demo"] as NSDictionary)
            .write(to: app.appendingPathComponent("Info.plist"))
        let ipa = tmp.appendingPathComponent("in.ipa")
        try Subprocess.runChecked("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", payload.path, ipa.path])

        XCTAssertEqual(try IPAResigner.readBundleIdentifier(ipaURL: ipa), "com.demo.peek")
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter IPAResignerTests`
Expected: 编译失败（`readBundleIdentifier` 未定义）。

- [ ] **Step 3: 实现**（加到 `IPAResigner` 里，`findPayloadApp` 附近）

```swift
    /// 重签前 peek：解出 Payload/*.app/Info.plist 的 CFBundleIdentifier
    public static func readBundleIdentifier(ipaURL: URL) throws -> String {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("peek-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try Subprocess.runChecked("/usr/bin/ditto", ["-x", "-k", ipaURL.path, work.path])
        guard let app = findPayloadApp(in: work) else { throw ReSignError.appNotFound }
        return try AppBundle(appDir: app).bundleIdentifier()
    }
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter IPAResignerTests` → PASS（含新用例）。

- [ ] **Step 5: 提交**

```bash
git add Sources/ReSignKit/IPAResigner.swift Tests/ReSignKitTests/IPAResignerTests.swift
git commit -m "feat(resignkit): readBundleIdentifier peek helper"
```

---

### Task 3: SigningIdentity 模型 + KeychainSigningIdentityStore + SecKey 还原

**Files:**
- Create: `Sources/ReSignAppCore/SigningIdentity.swift`
- Create: `Sources/ReSignAppCore/SigningIdentityStore.swift`
- Test: `Tests/ReSignAppCoreTests/SigningIdentityStoreTests.swift`

**Interfaces:**
- Consumes: 无（用 Foundation/Security）。
- Produces:
  - `struct SigningIdentity: Equatable { let privateKeyDER: Data; let certificateDER: Data; let ascCertificateId: String }`
  - `protocol SigningIdentityStore { func identity(for: UUID) throws -> SigningIdentity?; func save(_:for:) throws; func remove(for:) throws }`
  - `final class KeychainSigningIdentityStore: SigningIdentityStore`（`init(service: String = ReSignAppIdentifiers.bundleID + ".signing")`）
  - `final class InMemorySigningIdentityStore: SigningIdentityStore`（测试/注入用）
  - `enum SigningKeyCodec { static func makeRSAPrivateKey(fromDER: Data) throws -> SecKey; static func privateKeyDER(_ key: SecKey) throws -> Data }`
  - `enum SigningIdentityError: Error { case keychain(OSStatus); case badKeyData }`

- [ ] **Step 1: 写失败测试**

```swift
// Tests/ReSignAppCoreTests/SigningIdentityStoreTests.swift
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
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter SigningIdentityStoreTests`
Expected: 编译失败（类型未定义）。

- [ ] **Step 3: 实现 SigningIdentity.swift**

```swift
// Sources/ReSignAppCore/SigningIdentity.swift
import Foundation
import Security

public struct SigningIdentity: Equatable {
    public let privateKeyDER: Data
    public let certificateDER: Data
    public let ascCertificateId: String
    public init(privateKeyDER: Data, certificateDER: Data, ascCertificateId: String) {
        self.privateKeyDER = privateKeyDER; self.certificateDER = certificateDER
        self.ascCertificateId = ascCertificateId
    }
}

public enum SigningIdentityError: Error, LocalizedError {
    case keychain(OSStatus)
    case badKeyData
    public var errorDescription: String? {
        switch self {
        case .keychain(let s): return "钥匙串错误(\(s))"
        case .badKeyData: return "私钥数据无法解析"
        }
    }
}

/// RSA 私钥 DER <-> SecKey
public enum SigningKeyCodec {
    public static func privateKeyDER(_ key: SecKey) throws -> Data {
        var err: Unmanaged<CFError>?
        guard let d = SecKeyCopyExternalRepresentation(key, &err) as Data? else { throw SigningIdentityError.badKeyData }
        return d
    }
    public static func makeRSAPrivateKey(fromDER der: Data) throws -> SecKey {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &err) else {
            throw SigningIdentityError.badKeyData
        }
        return key
    }
}
```

- [ ] **Step 4: 实现 SigningIdentityStore.swift**

```swift
// Sources/ReSignAppCore/SigningIdentityStore.swift
import Foundation
import Security

public protocol SigningIdentityStore {
    func identity(for accountID: UUID) throws -> SigningIdentity?
    func save(_ identity: SigningIdentity, for accountID: UUID) throws
    func remove(for accountID: UUID) throws
}

/// 存进钥匙串（generic password），value 是 {key,cert,ascId} 的 base64 JSON。
public final class KeychainSigningIdentityStore: SigningIdentityStore {
    let service: String
    public init(service: String = ReSignAppIdentifiers.bundleID + ".signing") { self.service = service }

    private struct Blob: Codable { let key: String; let cert: String; let ascId: String }

    public func save(_ identity: SigningIdentity, for accountID: UUID) throws {
        try remove(for: accountID)
        let blob = Blob(key: identity.privateKeyDER.base64EncodedString(),
                        cert: identity.certificateDER.base64EncodedString(),
                        ascId: identity.ascCertificateId)
        let data = try JSONEncoder().encode(blob)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked]
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw SigningIdentityError.keychain(status) }
    }

    public func identity(for accountID: UUID) throws -> SigningIdentity? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw SigningIdentityError.keychain(status) }
        let blob = try JSONDecoder().decode(Blob.self, from: data)
        guard let key = Data(base64Encoded: blob.key), let cert = Data(base64Encoded: blob.cert) else {
            throw SigningIdentityError.badKeyData
        }
        return SigningIdentity(privateKeyDER: key, certificateDER: cert, ascCertificateId: blob.ascId)
    }

    public func remove(for accountID: UUID) throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString]
        let status = SecItemDelete(q as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SigningIdentityError.keychain(status) }
    }
}

public final class InMemorySigningIdentityStore: SigningIdentityStore {
    private var map: [UUID: SigningIdentity] = [:]
    public init() {}
    public func identity(for accountID: UUID) throws -> SigningIdentity? { map[accountID] }
    public func save(_ identity: SigningIdentity, for accountID: UUID) throws { map[accountID] = identity }
    public func remove(for accountID: UUID) throws { map[accountID] = nil }
}
```

- [ ] **Step 5: 运行确认通过**

Run: `swift test --filter SigningIdentityStoreTests` → PASS（3/3；钥匙串往返 + SecKey 还原可签名 + 内存实现）。

- [ ] **Step 6: 提交**

```bash
git add Sources/ReSignAppCore/SigningIdentity.swift Sources/ReSignAppCore/SigningIdentityStore.swift Tests/ReSignAppCoreTests/SigningIdentityStoreTests.swift
git commit -m "feat(resignapp): signing identity model + keychain store + SecKey codec"
```

---

### Task 4: SigningIdentityManager.createAndStore（自建证书）

**Files:**
- Create: `Sources/ReSignAppCore/SigningIdentityManager.swift`
- Test: `Tests/ReSignAppCoreTests/SigningIdentityManagerTests.swift`

**Interfaces:**
- Consumes: `SigningIdentity`/`SigningIdentityStore`（Task 3）、`ASCClient`/`ASCCredentials`/`SigningKeyPair`/`CertificateInfo`（UDIDRegisterKit）。
- Produces:
  - `final class SigningIdentityManager`：`init(store: SigningIdentityStore)`
    - `func createAndStore(for account: AppleAccount, cred: ASCCredentials, client: ASCClient) async throws -> SigningIdentity`
    - `func identity(for accountID: UUID) throws -> SigningIdentity?`（透传 store）

- [ ] **Step 1: 写失败测试**

```swift
// Tests/ReSignAppCoreTests/SigningIdentityManagerTests.swift
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
```

> 注：`MockHTTP` 与 `HTTPResponse` 来自 `UDIDRegisterKit` 的测试支撑吗？——不是。`MockHTTP` 定义在 `UDIDRegisterKitTests`，**不可跨测试 target 复用**。本 Task 需在 `ReSignAppCoreTests` 自带一份最小 `MockHTTP`。见 Step 3。

- [ ] **Step 2: 在 ReSignAppCoreTests 建最小 MockHTTP**

```swift
// Tests/ReSignAppCoreTests/TestSupport.swift
import Foundation
import UDIDRegisterKit

final class MockHTTP: HTTPClient, @unchecked Sendable {
    let handler: (String, String) -> HTTPResponse
    init(_ handler: @escaping (String, String) -> HTTPResponse) { self.handler = handler }
    func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> HTTPResponse {
        handler(method, url.path)
    }
    static func json(_ status: Int, _ obj: [String: Any]) -> HTTPResponse {
        HTTPResponse(status: status, body: try! JSONSerialization.data(withJSONObject: obj))
    }
}
```

- [ ] **Step 3: 运行确认失败**

Run: `swift test --filter SigningIdentityManagerTests`
Expected: 编译失败（`SigningIdentityManager` 未定义）。

- [ ] **Step 4: 实现**

```swift
// Sources/ReSignAppCore/SigningIdentityManager.swift
import Foundation
import Security
import UDIDRegisterKit

public final class SigningIdentityManager {
    let store: SigningIdentityStore
    public init(store: SigningIdentityStore) { self.store = store }

    public func identity(for accountID: UUID) throws -> SigningIdentity? {
        try store.identity(for: accountID)
    }

    /// 本机生成密钥对 → 提交 CSR 建发布证书 → 组 SigningIdentity 并持久化。
    public func createAndStore(for account: AppleAccount, cred: ASCCredentials,
                               client: ASCClient) async throws -> SigningIdentity {
        let kp = try SigningKeyPair.generateRSA2048()
        let csr = try kp.makeCSR(commonName: account.displayName)
        let cert = try await client.createCertificate(credentials: cred, csrDER: csr, type: .distribution)
        let identity = SigningIdentity(privateKeyDER: try SigningKeyCodec.privateKeyDER(kp.privateKey),
                                       certificateDER: cert.contentDER, ascCertificateId: cert.id)
        try store.save(identity, for: account.id)
        return identity
    }
}
```

- [ ] **Step 5: 运行确认通过**

Run: `swift test --filter SigningIdentityManagerTests` → PASS。

- [ ] **Step 6: 提交**

```bash
git add Sources/ReSignAppCore/SigningIdentityManager.swift Tests/ReSignAppCoreTests/SigningIdentityManagerTests.swift Tests/ReSignAppCoreTests/TestSupport.swift
git commit -m "feat(resignapp): SigningIdentityManager.createAndStore (app-created cert)"
```

---

### Task 5: SigningIdentityManager.importP12（导入已有 p12）

**Files:**
- Modify: `Sources/ReSignAppCore/SigningIdentityManager.swift`
- Test: `Tests/ReSignAppCoreTests/SigningIdentityManagerTests.swift`（追加）

**Interfaces:**
- Consumes: 同上 + `ASCClient.listCertificates`。
- Produces:
  - `func importP12(_ data: Data, password: String, for account: AppleAccount, cred: ASCCredentials, client: ASCClient) async throws -> SigningIdentity`
  - `enum SigningIdentityError` 追加 `case p12Import(OSStatus)` 与 `case certNotOnAccount`

- [ ] **Step 1: 追加失败测试**

```swift
// 追加到 SigningIdentityManagerTests
    /// 用测试现造的 p12（openssl）导入：私钥+证书拆出、且按证书内容在账号上匹配到 ASC id
    func testImportP12MatchesAccountCertAndStores() async throws {
        for t in ["/usr/bin/openssl"] { guard FileManager.default.isExecutableFile(atPath: t) else { throw XCTSkip("no \(t)") } }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // 造 key + 自签名证书 + p12（口令非空）
        let (p12Data, certDER) = try Self.makeTestP12(in: tmp, password: "pw")
        // 账号上「已注册」的证书列表里含这张（按 certificateContent 匹配）
        let c = client { method, _ in
            MockHTTP.json(200, ["data": [["id": "CERTX",
                "attributes": ["certificateContent": certDER.base64EncodedString()]]]])
        }
        let store = InMemorySigningIdentityStore()
        let mgr = SigningIdentityManager(store: store)
        let identity = try await mgr.importP12(p12Data, password: "pw", for: account, cred: cred, client: c)
        XCTAssertEqual(identity.ascCertificateId, "CERTX")
        XCTAssertEqual(identity.certificateDER, certDER)
        XCTAssertFalse(identity.privateKeyDER.isEmpty)
        XCTAssertEqual(try store.identity(for: account.id), identity)
    }

    func testImportP12FailsWhenCertNotOnAccount() async throws {
        for t in ["/usr/bin/openssl"] { guard FileManager.default.isExecutableFile(atPath: t) else { throw XCTSkip("no \(t)") } }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (p12Data, _) = try Self.makeTestP12(in: tmp, password: "pw")
        let c = client { _, _ in MockHTTP.json(200, ["data": []]) }   // 账号上没有任何证书
        let mgr = SigningIdentityManager(store: InMemorySigningIdentityStore())
        do { _ = try await mgr.importP12(p12Data, password: "pw", for: account, cred: cred, client: c); XCTFail("应抛错") }
        catch SigningIdentityError.certNotOnAccount {} // ok
    }

    /// 现造一张自签名代码签名证书 + p12，返回 (p12Data, certDER)
    static func makeTestP12(in dir: URL, password: String) throws -> (Data, Data) {
        func sh(_ args: [String]) throws { _ = try Subprocess.runChecked("/usr/bin/openssl", args) }
        let key = dir.appendingPathComponent("k.pem"), certPEM = dir.appendingPathComponent("c.pem")
        let certDERURL = dir.appendingPathComponent("c.der"), p12 = dir.appendingPathComponent("id.p12")
        try sh(["genrsa", "-out", key.path, "2048"])
        try sh(["req", "-x509", "-new", "-key", key.path, "-subj", "/CN=ReSign Test", "-days", "1", "-out", certPEM.path])
        try sh(["x509", "-in", certPEM.path, "-outform", "DER", "-out", certDERURL.path])
        try sh(["pkcs12", "-export", "-inkey", key.path, "-in", certPEM.path, "-out", p12.path,
                "-passout", "pass:\(password)", "-name", "ReSign Test"])
        return (try Data(contentsOf: p12), try Data(contentsOf: certDERURL))
    }
```

> `Subprocess` 属 `ReSignKit`；`SigningIdentityManagerTests` 需 `import ReSignKit` 才能用它造 p12。

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter SigningIdentityManagerTests`
Expected: 编译失败（`importP12` 未定义）。

- [ ] **Step 3: 追加实现**（同文件，`SigningIdentityError` 加两个 case，`SigningIdentityManager` 加方法）

在 `SigningIdentity.swift` 的 `SigningIdentityError` 里追加：
```swift
    case p12Import(OSStatus)
    case certNotOnAccount
```
并在其 `errorDescription` switch 追加：
```swift
        case .p12Import(let s): return "p12 导入失败(\(s))，检查密码"
        case .certNotOnAccount: return "该 p12 的证书未在此账号注册，无法用于构建描述文件"
```

在 `SigningIdentityManager.swift` 加：
```swift
    /// 导入 p12：拆出私钥+证书；按证书内容在账号已注册证书里匹配 ASC id；持久化。
    public func importP12(_ data: Data, password: String, for account: AppleAccount,
                          cred: ASCCredentials, client: ASCClient) async throws -> SigningIdentity {
        let opts: [String: Any] = [kSecImportExportPassphrase as String: password]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, opts as CFDictionary, &items)
        guard status == errSecSuccess,
              let arr = items as? [[String: Any]], let first = arr.first,
              let secIdentity = first[kSecImportItemIdentity as String] else {
            throw SigningIdentityError.p12Import(status)
        }
        let identityRef = secIdentity as! SecIdentity
        var privKey: SecKey?
        guard SecIdentityCopyPrivateKey(identityRef, &privKey) == errSecSuccess, let key = privKey else {
            throw SigningIdentityError.p12Import(errSecInvalidItemRef)
        }
        var certRef: SecCertificate?
        guard SecIdentityCopyCertificate(identityRef, &certRef) == errSecSuccess, let cert = certRef else {
            throw SigningIdentityError.p12Import(errSecInvalidItemRef)
        }
        let certDER = SecCertificateCopyData(cert) as Data

        // 在账号已注册证书里按内容匹配出 ASC 资源 id
        let onAccount = try await client.listCertificates(credentials: cred, type: .distribution)
        guard let match = onAccount.first(where: { $0.contentDER == certDER }) else {
            throw SigningIdentityError.certNotOnAccount
        }
        let identity = SigningIdentity(privateKeyDER: try SigningKeyCodec.privateKeyDER(key),
                                       certificateDER: certDER, ascCertificateId: match.id)
        try store.save(identity, for: account.id)
        return identity
    }
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter SigningIdentityManagerTests` → PASS（含 2 个新 p12 用例）。

- [ ] **Step 5: 提交**

```bash
git add Sources/ReSignAppCore/SigningIdentity.swift Sources/ReSignAppCore/SigningIdentityManager.swift Tests/ReSignAppCoreTests/SigningIdentityManagerTests.swift
git commit -m "feat(resignapp): SigningIdentityManager.importP12 (match ASC cert id)"
```

---

### Task 6: ReSignModel —— 账号库 + 导入 + 签名身份状态

**Files:**
- Create: `Sources/ReSignAppCore/ReSignModel.swift`
- Test: `Tests/ReSignAppCoreTests/ReSignModelTests.swift`

**Interfaces:**
- Consumes: `AccountStore`/`KeychainSecretStore`/`SecretStore`/`InMemorySecretStore`/`ASCClient`/`AppleAccount`/`AccountConfigCodec`（UDIDRegisterKit）、`SigningIdentityManager`/`InMemorySigningIdentityStore`（Task 3-5）。
- Produces:
  - `enum IdentityStatus: Equatable { case notCreated; case ready }`
  - `@MainActor @Observable final class ReSignModel`：
    - `var accounts: [AppleAccount]`、`var selectedID: UUID?`、`var log: [String]`、`var busy: Bool`、`var banner: String?`
    - `init(store: AccountStore, secrets: SecretStore, identity: SigningIdentityManager, client: ASCClient)`
    - `var selected: AppleAccount?`
    - `func identityStatus(for accountID: UUID) -> IdentityStatus`
    - `func importAccountConfig(from url: URL) async -> Bool`（复用 `AccountConfigCodec` + 校验 + 存）
    - `func deleteAccount(id: UUID)`

- [ ] **Step 1: 写失败测试**

```swift
// Tests/ReSignAppCoreTests/ReSignModelTests.swift
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
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter ReSignModelTests`
Expected: 编译失败（`ReSignModel` 未定义）。

- [ ] **Step 3: 实现**

```swift
// Sources/ReSignAppCore/ReSignModel.swift
import Foundation
import Observation
import UDIDRegisterKit
import ReSignKit

public enum IdentityStatus: Equatable { case notCreated; case ready }

public enum ReSignAppError: LocalizedError {
    case msg(String)
    public var errorDescription: String? { if case let .msg(m) = self { return m }; return nil }
}

@MainActor
@Observable
public final class ReSignModel {
    public var accounts: [AppleAccount] = []
    public var selectedID: UUID?
    public var log: [String] = []
    public var busy = false
    public var banner: String?
    public var selectedIPA: URL?

    let store: AccountStore
    let secrets: SecretStore
    let identity: SigningIdentityManager
    let client: ASCClient

    public init(store: AccountStore, secrets: SecretStore,
                identity: SigningIdentityManager, client: ASCClient) {
        self.store = store; self.secrets = secrets; self.identity = identity; self.client = client
        reload()
    }

    public func reload() {
        accounts = store.accounts
        if selectedID == nil || !accounts.contains(where: { $0.id == selectedID }) {
            selectedID = accounts.first?.id
        }
    }
    public var selected: AppleAccount? { accounts.first { $0.id == selectedID } }

    public func identityStatus(for accountID: UUID) -> IdentityStatus {
        ((try? identity.identity(for: accountID)) ?? nil) == nil ? .notCreated : .ready
    }

    func credentials(for a: AppleAccount) throws -> ASCCredentials {
        guard let pem = try secrets.load(for: a.id) else { throw ReSignAppError.msg("找不到该账号的 .p8，请重新导入账号") }
        return ASCCredentials(keyID: a.keyID, issuerID: a.issuerID, privateKeyPEM: pem)
    }

    /// 复用注册助手导出的 AccountConfig：解析 → 联网校验 → 存账号 + .p8。
    public func importAccountConfig(from url: URL) async -> Bool {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { banner = "读取配置文件失败：\(UserFacingMessage.from(error))"; return false }
        let config: AccountConfig
        do { config = try AccountConfigCodec.decode(data) }
        catch { banner = UserFacingMessage.from(error); return false }
        let account = AppleAccount(displayName: config.displayName, keyID: config.keyID,
                                   issuerID: config.issuerID, teamID: config.teamID)
        let cred = ASCCredentials(keyID: config.keyID, issuerID: config.issuerID, privateKeyPEM: config.p8PEM)
        do { _ = try await client.listDevices(credentials: cred) }
        catch { banner = "凭据校验失败：\(UserFacingMessage.from(error))"; return false }
        do { try secrets.save(config.p8PEM, for: account.id); try store.add(account) }
        catch { try? secrets.delete(for: account.id); banner = "保存失败：\(UserFacingMessage.from(error))"; return false }
        reload(); selectedID = account.id; banner = nil
        return true
    }

    public func deleteAccount(id: UUID) {
        try? secrets.delete(for: id)
        try? identity.store.remove(for: id)
        try? store.remove(id: id)
        reload()
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter ReSignModelTests` → PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/ReSignAppCore/ReSignModel.swift Tests/ReSignAppCoreTests/ReSignModelTests.swift
git commit -m "feat(resignapp): ReSignModel accounts + config import + identity status"
```

---

### Task 7: ReSignModel.resign() —— 一键重签流水线编排

**Files:**
- Modify: `Sources/ReSignAppCore/ReSignModel.swift`（加 resign + 可注入闭包）
- Test: `Tests/ReSignAppCoreTests/ReSignModelTests.swift`（追加）

**Interfaces:**
- Consumes: 上述全部 + `ReSignKit`。
- Produces（加到 `ReSignModel`）：
  - 可注入闭包（默认真实实现，测试注入假的）：
    - `var readBundleID: (URL) throws -> String`（默认 `IPAResigner.readBundleIdentifier`）
    - `var performResign: (_ ipaURL: URL, _ outputURL: URL, _ identity: SigningIdentity, _ mobileprovisionData: Data) throws -> Void`（默认 `ReSignModel.defaultPerformResign`）
  - `func resign() async`（跑 8 步流水线，写 `log`，出错写 `banner`）
  - `static func defaultPerformResign(...)`（组 `TemporaryKeychainIdentity` + `IPAResigner.resign`）

- [ ] **Step 1: 追加失败测试**

```swift
// 追加到 ReSignModelTests
    func testResignPipelineOrderAndDeviceIds() async throws {
        // client: findOrCreateBundleId(GET 空→POST 建)、listDevices 两台、createAdHocProfile 返回 profile
        let profileData = Data([0xAB, 0xCD])
        let c = ASCClient(http: MockHTTP { method, path in
            if path.hasSuffix("v1/bundleIds") { // GET 空 → POST 建
                return method == "GET" ? MockHTTP.json(200, ["data": []])
                    : MockHTTP.json(201, ["data": ["id": "B1", "attributes": ["identifier": "com.demo.app", "name": "com.demo.app"]]])
            }
            if path.hasSuffix("v1/devices") {
                return MockHTTP.json(200, ["data": [
                    ["id": "D1", "attributes": ["udid": "u1", "name": "d1", "status": "ENABLED"]],
                    ["id": "D2", "attributes": ["udid": "u2", "name": "d2", "status": "ENABLED"]]]])
            }
            if path.hasSuffix("v1/profiles") { // 无同名删除(GET 空) → POST 建
                return method == "GET" ? MockHTTP.json(200, ["data": []])
                    : MockHTTP.json(201, ["data": ["id": "P1", "attributes": ["name": "n", "profileContent": profileData.base64EncodedString()]]])
            }
            return MockHTTP.json(200, ["data": []])
        }, signJWT: { _ in "T" })

        let (m, idStore) = try makeModel(client: c)
        // 装一个账号 + 一套身份
        let acc = AppleAccount(displayName: "A", keyID: "K", issuerID: "I")
        try m.store.add(acc); try m.secrets.save("PEM", for: acc.id); m.reload(); m.selectedID = acc.id
        try idStore.save(SigningIdentity(privateKeyDER: Data([1]), certificateDER: Data([2]), ascCertificateId: "CERT1"), for: acc.id)

        // 注入假的 readBundleID / performResign（不碰真实 codesign）
        m.readBundleID = { _ in "com.demo.app" }
        var captured: (URL, URL, SigningIdentity, Data)?
        m.performResign = { ipa, out, id, mp in captured = (ipa, out, id, mp) }
        m.selectedIPA = URL(fileURLWithPath: "/tmp/demo.ipa")

        await m.resign()

        XCTAssertNil(m.banner, "不应有错误：\(m.banner ?? "")")
        let cap = try XCTUnwrap(captured)
        XCTAssertEqual(cap.1, URL(fileURLWithPath: "/tmp/demo-resigned.ipa"))  // 输出同目录 -resigned
        XCTAssertEqual(cap.2.ascCertificateId, "CERT1")
        XCTAssertEqual(cap.3, profileData)                                     // profile 内容透传
    }

    func testResignRefusesWhenNoIdentity() async throws {
        let c = ASCClient(http: MockHTTP { _, _ in MockHTTP.json(200, ["data": []]) }, signJWT: { _ in "T" })
        let (m, _) = try makeModel(client: c)
        let acc = AppleAccount(displayName: "A", keyID: "K", issuerID: "I")
        try m.store.add(acc); try m.secrets.save("PEM", for: acc.id); m.reload(); m.selectedID = acc.id
        m.selectedIPA = URL(fileURLWithPath: "/tmp/demo.ipa")
        m.readBundleID = { _ in "com.demo.app" }
        await m.resign()
        XCTAssertNotNil(m.banner)  // 无签名身份 → 报错中止
    }

    func testResignSurfacesUnsupportedNestedBundle() async throws {
        let profileData = Data([0x01])
        let c = ASCClient(http: MockHTTP { method, path in
            if path.hasSuffix("v1/bundleIds") { return MockHTTP.json(201, ["data": ["id": "B", "attributes": ["identifier": "x", "name": "x"]]]) }
            if path.hasSuffix("v1/devices") { return MockHTTP.json(200, ["data": []]) }
            if path.hasSuffix("v1/profiles") { return method == "GET" ? MockHTTP.json(200, ["data": []]) : MockHTTP.json(201, ["data": ["id": "P", "attributes": ["profileContent": profileData.base64EncodedString()]]]) }
            return MockHTTP.json(200, ["data": []])
        }, signJWT: { _ in "T" })
        let (m, idStore) = try makeModel(client: c)
        let acc = AppleAccount(displayName: "A", keyID: "K", issuerID: "I")
        try m.store.add(acc); try m.secrets.save("PEM", for: acc.id); m.reload(); m.selectedID = acc.id
        try idStore.save(SigningIdentity(privateKeyDER: Data([1]), certificateDER: Data([2]), ascCertificateId: "C"), for: acc.id)
        m.selectedIPA = URL(fileURLWithPath: "/tmp/demo.ipa")
        m.readBundleID = { _ in "com.demo.app" }
        m.performResign = { _, _, _, _ in throw ReSignError.unsupportedNestedBundle(["Ext.appex"]) }
        await m.resign()
        XCTAssertNotNil(m.banner)
        XCTAssertTrue(m.banner!.contains("扩展") || m.banner!.contains("Ext.appex"))
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter ReSignModelTests`
Expected: 编译失败（`resign`/`readBundleID`/`performResign` 未定义）。

- [ ] **Step 3: 实现**（加到 `ReSignModel`）

在 `ReSignModel` 的存储属性区加两个可注入闭包（带默认值）：
```swift
    public var readBundleID: (URL) throws -> String = { try IPAResigner.readBundleIdentifier(ipaURL: $0) }
    public var performResign: (_ ipaURL: URL, _ outputURL: URL, _ identity: SigningIdentity, _ mobileprovisionData: Data) throws -> Void
        = ReSignModel.defaultPerformResign
```

加流水线与默认重签实现：
```swift
    /// 一键重签：读 bundleId → 确保 App ID → 全部设备 → 刷描述文件 → 重签 → Finder 显示。
    public func resign() async {
        banner = nil; log = []
        guard let a = selected else { banner = "请先选择账号"; return }
        guard let ipa = selectedIPA else { banner = "请先选择 IPA"; return }
        guard let signing = try? identity.identity(for: a.id), signing != nil, let sid = signing else {
            banner = "该账号还没有签名身份，请先「自动创建」或「导入 p12」"; return
        }
        busy = true; defer { busy = false }
        do {
            let cred = try credentials(for: a)
            log.append("读取 IPA 的 bundle id…")
            let bundleID = try readBundleID(ipa)
            log.append("bundle id：\(bundleID)")
            log.append("确认 App ID…")
            let bundle = try await client.findOrCreateBundleId(credentials: cred, identifier: bundleID, name: bundleID)
            log.append("获取账号下全部设备…")
            let devices = try await client.listDevices(credentials: cred)
            log.append("设备 \(devices.count) 台，刷新 Ad Hoc 描述文件…")
            let profile = try await client.refreshAdHocProfile(
                credentials: cred, name: "ReSign AdHoc \(bundleID)",
                bundleIdResourceId: bundle.id, certificateId: sid.ascCertificateId,
                deviceIds: devices.map { $0.id })
            let output = ipa.deletingLastPathComponent()
                .appendingPathComponent(ipa.deletingPathExtension().lastPathComponent + "-resigned.ipa")
            log.append("重签中…")
            try performResign(ipa, output, sid, profile.contentData)
            log.append("✅ 完成：\(output.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([output])
        } catch {
            banner = UserFacingMessage.from(error)
            log.append("❌ 失败：\(banner ?? "")")
        }
    }

    /// 默认重签：还原私钥 → 组临时钥匙串身份 → IPAResigner。
    public static func defaultPerformResign(ipaURL: URL, outputURL: URL,
                                            identity sid: SigningIdentity, mobileprovisionData: Data) throws {
        let key = try SigningKeyCodec.makeRSAPrivateKey(fromDER: sid.privateKeyDER)
        let tki = try TemporaryKeychainIdentity(privateKey: key, certificateDER: sid.certificateDER, commonName: "ReSign")
        defer { tki.cleanup() }
        try tki.addToSearchListForCodesign()
        try IPAResigner.resign(ipaURL: ipaURL, outputURL: outputURL, identity: tki, mobileprovisionData: mobileprovisionData)
    }
```

在文件顶部 `import` 区补 `import AppKit`（用 `NSWorkspace`）。

- [ ] **Step 4: 运行确认通过**

Run: `swift test`（全量，确认无回归 + 新 3 个 resign 用例通过）
Expected: 全绿。

- [ ] **Step 5: 提交**

```bash
git add Sources/ReSignAppCore/ReSignModel.swift Tests/ReSignAppCoreTests/ReSignModelTests.swift
git commit -m "feat(resignapp): one-tap resign pipeline orchestration (injectable, tested)"
```

---

## Self-Review

**Spec coverage：**
- 目标 target 分层（ReSignAppCore 库可测 + ReSignApp 可执行）→ Task 1 ✅
- IPA peek bundle id → Task 2 ✅
- 签名身份持久化 + SecKey 还原 → Task 3 ✅
- 自建证书 → Task 4 ✅
- 导入 p12 + 账号证书 id 匹配 → Task 5 ✅
- 账号库 + AccountConfig 导入 + 身份状态 → Task 6 ✅
- 一键重签流水线（全部设备、profile-first、错误分支）→ Task 7 ✅
- **不在本计划**：SwiftUI 视图 / @main / 打包 / `exportP12`（计划 4）。

**Placeholder scan：** 无 TBD/TODO；每步含完整代码。

**Type consistency：** `SigningIdentity`（Task 3）字段在 4/5/6/7 一致；`SigningIdentityManager.identity/createAndStore/importP12`（Task 4-5）签名一致；`ReSignModel` 的 `readBundleID`/`performResign`/`resign`（Task 7）与注入点一致；`MockHTTP` 在 ReSignAppCoreTests 自带（Task 4 建），不跨 target 复用 UDIDRegisterKitTests 的版本。`deleteAccount` 访问 `identity.store`（`SigningIdentityManager.store` 为 internal，同模块可达）。

**边界/依赖：** 全部逻辑在 `ReSignAppCore`，可 `swift test` 独立验证；`performResign`/`readBundleID` 默认走真实 ReSignKit，测试注入假实现，因此编排与错误分支不碰真实 codesign/钥匙串。真实端到端在计划 4（UI）接好后手测。
