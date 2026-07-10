# UDID 注册助手（macOS）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 一个纯本地的 macOS 原生 app：管理多个苹果开发者账号凭据，把测试机 UDID 批量录入并直接调 App Store Connect API 注册，显示每台真实状态。

**Architecture:** 分两层。**UDIDRegisterKit**（Swift Package library target）承载全部纯逻辑（JWT 签名、ASC 调用、UDID 规范化、批量解析、Keychain/账号存储），用 XCTest 做 TDD，`swift test` headless 可跑。**UDIDRegisterApp**（同一 Package 的 executable target，SwiftUI）是薄 UI 壳，只做展示与编排，调用 Kit。

**Tech Stack:** Swift 5.9 / SwiftUI / CryptoKit（ES256）/ Security（Keychain）/ URLSession。无第三方依赖。SPM 单包三 target。

## Global Constraints

- Swift tools 5.9+；macOS 部署目标 **14.0**（用 Observation `@Observable` 与现代 SwiftUI）。
- **零第三方依赖**：仅 Foundation / CryptoKit / Security / SwiftUI / AppKit。
- `.p8` 私钥**只存 Keychain**，绝不写磁盘明文、绝不进日志。
- JWT：`iat = now - 30`（回拨 30s，避免本机时钟略快被判未来 token → 401）；`exp = now + 1100`；`aud = "appstoreconnect-v1"`；`alg = ES256`。
- ASC base URL：`https://api.appstoreconnect.apple.com`；设备端点 `/v1/devices`。
- UDID 规范化：先 trim+小写；`^[0-9a-f]{8}-[0-9a-f]{16}$` → **大写**返回；`^[0-9a-f]{40}$` → **小写**原样返回；否则 `nil`。
- 注册结果三态：`created(status)` / `alreadyExisted(name,status)` / `failed(message)`。409 时回查设备列表按 UDID 匹配取状态；查不到降级为 Apple 原始 detail。
- 状态文案：ENABLED→`✅ 已可用 — 可直接用于真机调试/打包`；PROCESSING→`⏳ 处理中 — 苹果正在处理，可能需 24~72 小时才可供开发使用`；DISABLED→`🚫 已禁用 — 仍占用 100 台/年额度`。
- 账号只存元数据（displayName/keyID/issuerID/teamID?）到 Application Support 的 `accounts.json`；`.p8` 用 `AppleAccount.id` 关联 Keychain。

---

## 文件结构

```
UDIDRegisterMac/
├── Package.swift
├── Sources/
│   ├── UDIDRegisterKit/
│   │   ├── Models.swift            # AppleAccount, ASCCredentials, DeviceInput, DeviceStatus, DeviceRow, RegistrationOutcome
│   │   ├── UDIDNormalizer.swift    # normalize(_:)
│   │   ├── DeviceInputParser.swift # parse(_:) 批量文本 → [DeviceInput]
│   │   ├── ASCJWT.swift            # sign(...) ES256
│   │   ├── HTTPClient.swift        # HTTPResponse, HTTPClient 协议, URLSessionHTTPClient
│   │   ├── ASCClient.swift         # registerDevice / listDevices / ASCError
│   │   ├── SecretStore.swift       # SecretStore 协议 + InMemory + Keychain
│   │   └── AccountStore.swift      # 账号元数据持久化
│   └── UDIDRegisterApp/
│       ├── UDIDRegisterApp.swift   # @main + AppDelegate（激活策略）
│       ├── AppModel.swift          # @Observable 编排
│       ├── StatusText.swift        # 状态/结果 → 中文文案
│       ├── RootView.swift          # 账号选择 + 额度 + 录入 + 结果
│       ├── AccountManagerView.swift# 账号增删改 + 测试连接
│       └── RegisterView.swift      # 批量录入 + 结果列表
└── Tests/UDIDRegisterKitTests/
    ├── UDIDNormalizerTests.swift
    ├── DeviceInputParserTests.swift
    ├── ASCJWTTests.swift
    ├── ASCClientTests.swift
    ├── SecretStoreTests.swift
    ├── AccountStoreTests.swift
    └── TestSupport.swift           # base64url 解码、MockHTTP
```

---

## Phase A — UDIDRegisterKit（TDD，`swift test`）

### Task 1: Package 骨架 + Models + UDIDNormalizer

**Files:**
- Create: `Package.swift`
- Create: `Sources/UDIDRegisterKit/Models.swift`
- Create: `Sources/UDIDRegisterKit/UDIDNormalizer.swift`
- Test: `Tests/UDIDRegisterKitTests/UDIDNormalizerTests.swift`

**Interfaces:**
- Produces: `UDIDNormalizer.normalize(_ raw: String) -> String?`；类型 `AppleAccount`, `ASCCredentials`, `DeviceInput`, `DeviceStatus`, `DeviceRow`, `RegistrationOutcome`。

- [ ] **Step 1: 写 Package.swift**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UDIDRegisterMac",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "UDIDRegisterKit"),
        .testTarget(name: "UDIDRegisterKitTests", dependencies: ["UDIDRegisterKit"]),
        .executableTarget(name: "UDIDRegisterApp", dependencies: ["UDIDRegisterKit"]),
    ]
)
```

- [ ] **Step 2: 写 Models.swift**

```swift
import Foundation

public struct AppleAccount: Identifiable, Codable, Hashable {
    public let id: UUID
    public var displayName: String
    public var keyID: String
    public var issuerID: String
    public var teamID: String?
    public init(id: UUID = UUID(), displayName: String, keyID: String, issuerID: String, teamID: String? = nil) {
        self.id = id; self.displayName = displayName; self.keyID = keyID
        self.issuerID = issuerID; self.teamID = teamID
    }
}

public struct ASCCredentials {
    public let keyID: String
    public let issuerID: String
    public let privateKeyPEM: String
    public init(keyID: String, issuerID: String, privateKeyPEM: String) {
        self.keyID = keyID; self.issuerID = issuerID; self.privateKeyPEM = privateKeyPEM
    }
}

public struct DeviceInput: Identifiable, Hashable {
    public let id: UUID
    public var udidRaw: String
    public var name: String
    public init(id: UUID = UUID(), udidRaw: String, name: String) {
        self.id = id; self.udidRaw = udidRaw; self.name = name
    }
}

public enum DeviceStatus: String, Codable, Hashable {
    case enabled = "ENABLED"
    case processing = "PROCESSING"
    case disabled = "DISABLED"
    case unknown = "UNKNOWN"
    public static func from(_ raw: String?) -> DeviceStatus {
        guard let raw else { return .unknown }
        return DeviceStatus(rawValue: raw) ?? .unknown
    }
}

public struct DeviceRow: Identifiable, Hashable {
    public let id: String
    public var name: String
    public var udid: String
    public var status: DeviceStatus
    public var model: String?
    public var addedDate: String?
    public init(id: String, name: String, udid: String, status: DeviceStatus, model: String? = nil, addedDate: String? = nil) {
        self.id = id; self.name = name; self.udid = udid; self.status = status; self.model = model; self.addedDate = addedDate
    }
}

public enum RegistrationOutcome: Hashable {
    case created(status: DeviceStatus)
    case alreadyExisted(name: String, status: DeviceStatus)
    case failed(message: String)
}
```

- [ ] **Step 3: 写 UDIDNormalizer.swift**

```swift
import Foundation

public enum UDIDNormalizer {
    /// 规范化 UDID；非法返回 nil。
    /// 40 位十六进制 → 小写；8-16 带连字符 → 大写。
    public static func normalize(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.range(of: "^[0-9a-f]{8}-[0-9a-f]{16}$", options: .regularExpression) != nil {
            return s.uppercased()
        }
        if s.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil {
            return s
        }
        return nil
    }
}
```

- [ ] **Step 4: 写失败测试 UDIDNormalizerTests.swift**

```swift
import XCTest
@testable import UDIDRegisterKit

final class UDIDNormalizerTests: XCTestCase {
    func testModernUppercased() {
        XCTAssertEqual(UDIDNormalizer.normalize("00008110-001c24cc14fa601e"), "00008110-001C24CC14FA601E")
    }
    func testModernAlreadyUpper() {
        XCTAssertEqual(UDIDNormalizer.normalize("00008110-001C24CC14FA601E"), "00008110-001C24CC14FA601E")
    }
    func testLegacyLowercased() {
        let u = String(repeating: "a", count: 40)
        XCTAssertEqual(UDIDNormalizer.normalize(u.uppercased()), u)
    }
    func testTrimsWhitespace() {
        XCTAssertEqual(UDIDNormalizer.normalize("  00008110-001C24CC14FA601E \n"), "00008110-001C24CC14FA601E")
    }
    func testInvalidReturnsNil() {
        XCTAssertNil(UDIDNormalizer.normalize("not-a-udid"))
        XCTAssertNil(UDIDNormalizer.normalize("00008110-001C24CC14FA601"))   // 15 位尾段
        XCTAssertNil(UDIDNormalizer.normalize(String(repeating: "z", count: 40)))
    }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --filter UDIDNormalizerTests`
Expected: 全部 PASS（包 Package 首次会先编译）。

- [ ] **Step 6: 提交**

```bash
git add Package.swift Sources/UDIDRegisterKit/Models.swift Sources/UDIDRegisterKit/UDIDNormalizer.swift Tests/UDIDRegisterKitTests/UDIDNormalizerTests.swift
git commit -m "feat(kit): package scaffold, models, UDID normalizer"
```

---

### Task 2: DeviceInputParser（批量文本解析）

**Files:**
- Create: `Sources/UDIDRegisterKit/DeviceInputParser.swift`
- Test: `Tests/UDIDRegisterKitTests/DeviceInputParserTests.swift`

**Interfaces:**
- Produces: `DeviceInputParser.parse(_ text: String) -> [DeviceInput]`（每行 `UDID` 或 `UDID,名称`；空行忽略；名称缺省 `Device-<UDID去连字符后末6位大写>`）。

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import UDIDRegisterKit

final class DeviceInputParserTests: XCTestCase {
    func testSplitsLinesAndNames() {
        let inputs = DeviceInputParser.parse("00008110-001C24CC14FA601E, 张三 iPhone\n" +
                                             "  \n" +
                                             "abc123, 李四")
        XCTAssertEqual(inputs.count, 2)
        XCTAssertEqual(inputs[0].udidRaw, "00008110-001C24CC14FA601E")
        XCTAssertEqual(inputs[0].name, "张三 iPhone")
        XCTAssertEqual(inputs[1].udidRaw, "abc123")
        XCTAssertEqual(inputs[1].name, "李四")
    }
    func testDefaultNameWhenMissing() {
        let inputs = DeviceInputParser.parse("00008110-001C24CC14FA601E")
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs[0].name, "Device-FA601E")
    }
    func testEmptyNameAfterCommaGetsDefault() {
        let inputs = DeviceInputParser.parse("00008110-001C24CC14FA601E,   ")
        XCTAssertEqual(inputs[0].name, "Device-FA601E")
    }
    func testDropsLinesWithNoUdid() {
        XCTAssertTrue(DeviceInputParser.parse(",name\n\n").isEmpty)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter DeviceInputParserTests`
Expected: FAIL（`DeviceInputParser` 未定义）。

- [ ] **Step 3: 写实现 DeviceInputParser.swift**

```swift
import Foundation

public enum DeviceInputParser {
    public static func parse(_ text: String) -> [DeviceInput] {
        text.split(whereSeparator: \.isNewline).compactMap { raw -> DeviceInput? in
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            let parts = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            let udid = parts[0].trimmingCharacters(in: .whitespaces)
            guard !udid.isEmpty else { return nil }
            var name = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            if name.isEmpty { name = defaultName(for: udid) }
            return DeviceInput(udidRaw: udid, name: name)
        }
    }
    static func defaultName(for udid: String) -> String {
        let tail = udid.replacingOccurrences(of: "-", with: "").suffix(6).uppercased()
        return "Device-\(tail)"
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter DeviceInputParserTests`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/UDIDRegisterKit/DeviceInputParser.swift Tests/UDIDRegisterKitTests/DeviceInputParserTests.swift
git commit -m "feat(kit): batch device-input parser"
```

---

### Task 3: ASCJWT（ES256 签名）

**Files:**
- Create: `Sources/UDIDRegisterKit/ASCJWT.swift`
- Create: `Tests/UDIDRegisterKitTests/TestSupport.swift`
- Test: `Tests/UDIDRegisterKitTests/ASCJWTTests.swift`

**Interfaces:**
- Produces: `ASCJWT.sign(keyID:issuerID:privateKeyPEM:now:) throws -> String`（`now` 默认 `Date()`，可注入用于测试）；`ASCJWTError.invalidPrivateKey`。

- [ ] **Step 1: 写测试支撑 TestSupport.swift**

```swift
import Foundation

extension Data {
    /// 解码 base64url（无填充）
    init?(base64URLEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b) else { return nil }
        self = d
    }
}
```

- [ ] **Step 2: 写失败测试 ASCJWTTests.swift**

```swift
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
```

- [ ] **Step 3: 跑测试确认失败**

Run: `swift test --filter ASCJWTTests`
Expected: FAIL（`ASCJWT` 未定义）。

- [ ] **Step 4: 写实现 ASCJWT.swift**

```swift
import Foundation
import CryptoKit

public enum ASCJWTError: Error { case invalidPrivateKey }

public enum ASCJWT {
    public static func sign(keyID: String, issuerID: String,
                            privateKeyPEM: String, now: Date = Date()) throws -> String {
        let key: P256.Signing.PrivateKey
        do { key = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM) }
        catch { throw ASCJWTError.invalidPrivateKey }

        let t = Int(now.timeIntervalSince1970)
        let header: [String: Any] = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
        let payload: [String: Any] = ["iss": issuerID, "iat": t - 30,
                                      "exp": t + 1100, "aud": "appstoreconnect-v1"]
        let signingInput = try b64(header) + "." + b64(payload)
        let sig = try key.signature(for: Data(signingInput.utf8))
        return signingInput + "." + base64URL(sig.rawRepresentation)
    }

    static func b64(_ obj: [String: Any]) throws -> String {
        base64URL(try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]))
    }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --filter ASCJWTTests`
Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add Sources/UDIDRegisterKit/ASCJWT.swift Tests/UDIDRegisterKitTests/TestSupport.swift Tests/UDIDRegisterKitTests/ASCJWTTests.swift
git commit -m "feat(kit): ES256 ASC JWT signing"
```

---

### Task 4: HTTPClient + ASCClient（注册 / 列表 / 409 回查）

**Files:**
- Create: `Sources/UDIDRegisterKit/HTTPClient.swift`
- Create: `Sources/UDIDRegisterKit/ASCClient.swift`
- Modify: `Tests/UDIDRegisterKitTests/TestSupport.swift`（追加 MockHTTP）
- Test: `Tests/UDIDRegisterKitTests/ASCClientTests.swift`

**Interfaces:**
- Consumes: `ASCJWT.sign`、`ASCCredentials`、`DeviceStatus`、`DeviceRow`、`RegistrationOutcome`。
- Produces:
  - `protocol HTTPClient { func send(method:String, url:URL, headers:[String:String], body:Data?) async throws -> HTTPResponse }`；`struct HTTPResponse { let status:Int; let body:Data }`；`struct URLSessionHTTPClient: HTTPClient`。
  - `struct ASCClient { init(http:HTTPClient, signJWT:@escaping (ASCCredentials) throws -> String = ASCClient.defaultSign) }`
  - `ASCClient.registerDevice(credentials:name:udid:) async throws -> RegistrationOutcome`
  - `ASCClient.listDevices(credentials:) async throws -> [DeviceRow]`
  - `enum ASCError: LocalizedError { case http(Int, String) }`

- [ ] **Step 1: 写 HTTPClient.swift**

```swift
import Foundation

public struct HTTPResponse {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

public protocol HTTPClient {
    func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> HTTPResponse
}

public struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> HTTPResponse {
        var req = URLRequest(url: url)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        let (data, resp) = try await session.data(for: req)
        return HTTPResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}
```

- [ ] **Step 2: 写 ASCClient.swift**

```swift
import Foundation

public enum ASCError: LocalizedError {
    case http(Int, String)
    public var errorDescription: String? {
        if case let .http(s, d) = self { return d.isEmpty ? "ASC API \(s)" : d }
        return nil
    }
}

public struct ASCClient {
    static let base = URL(string: "https://api.appstoreconnect.apple.com")!
    let http: HTTPClient
    let signJWT: (ASCCredentials) throws -> String

    public init(http: HTTPClient,
                signJWT: @escaping (ASCCredentials) throws -> String = ASCClient.defaultSign) {
        self.http = http; self.signJWT = signJWT
    }
    public static func defaultSign(_ c: ASCCredentials) throws -> String {
        try ASCJWT.sign(keyID: c.keyID, issuerID: c.issuerID, privateKeyPEM: c.privateKeyPEM)
    }
    private func headers(_ c: ASCCredentials) throws -> [String: String] {
        ["Authorization": "Bearer \(try signJWT(c))", "Content-Type": "application/json"]
    }

    public func registerDevice(credentials c: ASCCredentials, name: String, udid: String) async throws -> RegistrationOutcome {
        let payload: [String: Any] = ["data": ["type": "devices",
            "attributes": ["name": name, "udid": udid, "platform": "IOS"]]]
        let resp = try await http.send(method: "POST",
            url: Self.base.appendingPathComponent("v1/devices"),
            headers: try headers(c), body: try JSONSerialization.data(withJSONObject: payload))
        let json = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any]

        if (200...299).contains(resp.status) {
            let attrs = (json?["data"] as? [String: Any])?["attributes"] as? [String: Any]
            return .created(status: DeviceStatus.from(attrs?["status"] as? String))
        }
        if resp.status == 409, let dev = try? await lookup(credentials: c, udid: udid) {
            return .alreadyExisted(name: dev.name, status: dev.status)
        }
        let detail = ((json?["errors"] as? [[String: Any]])?.first?["detail"] as? String) ?? "ASC API \(resp.status)"
        return .failed(message: detail)
    }

    public func listDevices(credentials c: ASCCredentials) async throws -> [DeviceRow] {
        var comp = URLComponents(url: Self.base.appendingPathComponent("v1/devices"), resolvingAgainstBaseURL: false)!
        comp.queryItems = [URLQueryItem(name: "limit", value: "200")]
        let resp = try await http.send(method: "GET", url: comp.url!, headers: try headers(c), body: nil)
        guard (200...299).contains(resp.status) else {
            let json = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any]
            let detail = ((json?["errors"] as? [[String: Any]])?.first?["detail"] as? String) ?? ""
            throw ASCError.http(resp.status, detail)
        }
        let json = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any]
        let arr = (json?["data"] as? [[String: Any]]) ?? []
        return arr.compactMap { item in
            guard let id = item["id"] as? String, let a = item["attributes"] as? [String: Any] else { return nil }
            return DeviceRow(id: id, name: a["name"] as? String ?? "", udid: a["udid"] as? String ?? "",
                             status: DeviceStatus.from(a["status"] as? String),
                             model: a["model"] as? String, addedDate: a["addedDate"] as? String)
        }
    }

    private func lookup(credentials c: ASCCredentials, udid: String) async throws -> DeviceRow? {
        let target = udid.uppercased()
        return try await listDevices(credentials: c).first { $0.udid.uppercased() == target }
    }
}
```

- [ ] **Step 3: 往 TestSupport.swift 追加 MockHTTP**

```swift
import Foundation
@testable import UDIDRegisterKit

/// 按 (method, path) 返回预设响应
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

- [ ] **Step 4: 写测试 ASCClientTests.swift**

```swift
import XCTest
@testable import UDIDRegisterKit

final class ASCClientTests: XCTestCase {
    let cred = ASCCredentials(keyID: "K", issuerID: "I", privateKeyPEM: "PEM")
    func makeClient(_ h: @escaping (String, String) -> HTTPResponse) -> ASCClient {
        ASCClient(http: MockHTTP(h), signJWT: { _ in "TESTTOKEN" })  // 跳过真实签名
    }

    func testCreatedReturnsStatus() async throws {
        let c = makeClient { _, _ in
            MockHTTP.json(201, ["data": ["id": "X", "attributes": ["status": "PROCESSING"]]])
        }
        let out = try await c.registerDevice(credentials: cred, name: "n", udid: "U")
        XCTAssertEqual(out, .created(status: .processing))
    }
    func testConflictLooksUpStatusAndName() async throws {
        let c = makeClient { method, _ in
            if method == "POST" { return MockHTTP.json(409, ["errors": [["detail": "exists"]]]) }
            return MockHTTP.json(200, ["data": [["id": "X",
                "attributes": ["udid": "00008110-001C24CC14FA601E", "name": "iPhone", "status": "ENABLED"]]]])
        }
        let out = try await c.registerDevice(credentials: cred, name: "newxp15", udid: "00008110-001C24CC14FA601E")
        XCTAssertEqual(out, .alreadyExisted(name: "iPhone", status: .enabled))
    }
    func testConflictNotFoundFallsBackToError() async throws {
        let c = makeClient { method, _ in
            if method == "POST" { return MockHTTP.json(409, ["errors": [["detail": "already exists"]]]) }
            return MockHTTP.json(200, ["data": []])
        }
        let out = try await c.registerDevice(credentials: cred, name: "n", udid: "U")
        XCTAssertEqual(out, .failed(message: "already exists"))
    }
    func testServerErrorFails() async throws {
        let c = makeClient { _, _ in MockHTTP.json(500, ["errors": [["detail": "boom"]]]) }
        let out = try await c.registerDevice(credentials: cred, name: "n", udid: "U")
        XCTAssertEqual(out, .failed(message: "boom"))
    }
    func testListDevicesMapsRows() async throws {
        let c = makeClient { _, _ in
            MockHTTP.json(200, ["data": [["id": "A", "attributes":
                ["udid": "u1", "name": "d1", "status": "ENABLED", "model": "iPhone 14"]]]])
        }
        let rows = try await c.listDevices(credentials: cred)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].status, .enabled)
        XCTAssertEqual(rows[0].model, "iPhone 14")
    }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --filter ASCClientTests`
Expected: 全部 PASS。

- [ ] **Step 6: 提交**

```bash
git add Sources/UDIDRegisterKit/HTTPClient.swift Sources/UDIDRegisterKit/ASCClient.swift Tests/UDIDRegisterKitTests/TestSupport.swift Tests/UDIDRegisterKitTests/ASCClientTests.swift
git commit -m "feat(kit): ASC client with register/list and 409 status lookup"
```

---

### Task 5: SecretStore + AccountStore（存储层）

**Files:**
- Create: `Sources/UDIDRegisterKit/SecretStore.swift`
- Create: `Sources/UDIDRegisterKit/AccountStore.swift`
- Test: `Tests/UDIDRegisterKitTests/SecretStoreTests.swift`
- Test: `Tests/UDIDRegisterKitTests/AccountStoreTests.swift`

**Interfaces:**
- Produces:
  - `protocol SecretStore { func save(_ pem:String, for id:UUID) throws; func load(for id:UUID) throws -> String?; func delete(for id:UUID) throws }`
  - `final class InMemorySecretStore: SecretStore`、`final class KeychainSecretStore: SecretStore`（`init(service:)`）
  - `final class AccountStore { init(fileURL:URL); var accounts:[AppleAccount]; static func defaultFileURL()->URL; func add(_:) throws; func update(_:) throws; func remove(id:) throws }`

- [ ] **Step 1: 写 SecretStore.swift**

```swift
import Foundation
import Security

public protocol SecretStore {
    func save(_ pem: String, for id: UUID) throws
    func load(for id: UUID) throws -> String?
    func delete(for id: UUID) throws
}

public final class InMemorySecretStore: SecretStore {
    private var store: [UUID: String] = [:]
    public init() {}
    public func save(_ pem: String, for id: UUID) throws { store[id] = pem }
    public func load(for id: UUID) throws -> String? { store[id] }
    public func delete(for id: UUID) throws { store[id] = nil }
}

public enum KeychainError: Error { case os(OSStatus) }

public final class KeychainSecretStore: SecretStore {
    let service: String
    public init(service: String = "com.yourco.UDIDRegisterMac") { self.service = service }

    public func save(_ pem: String, for id: UUID) throws {
        try delete(for: id)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecValueData as String: Data(pem.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked]
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.os(status) }
    }
    public func load(for id: UUID) throws -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError.os(status) }
        return String(decoding: data, as: UTF8.self)
    }
    public func delete(for id: UUID) throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString]
        let status = SecItemDelete(q as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.os(status) }
    }
}
```

- [ ] **Step 2: 写 AccountStore.swift**

```swift
import Foundation

public final class AccountStore {
    private let fileURL: URL
    public private(set) var accounts: [AppleAccount] = []

    public init(fileURL: URL) { self.fileURL = fileURL; load() }

    public static func defaultFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UDIDRegisterMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("accounts.json")
    }
    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([AppleAccount].self, from: data) else { return }
        accounts = list
    }
    private func persist() throws {
        try JSONEncoder().encode(accounts).write(to: fileURL, options: .atomic)
    }
    @discardableResult public func add(_ a: AppleAccount) throws -> AppleAccount {
        accounts.append(a); try persist(); return a
    }
    public func update(_ a: AppleAccount) throws {
        guard let i = accounts.firstIndex(where: { $0.id == a.id }) else { return }
        accounts[i] = a; try persist()
    }
    public func remove(id: UUID) throws {
        accounts.removeAll { $0.id == id }; try persist()
    }
}
```

- [ ] **Step 3: 写测试 SecretStoreTests.swift**

```swift
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
```

- [ ] **Step 4: 写测试 AccountStoreTests.swift**

```swift
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
```

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test`
Expected: 全 target 测试 PASS（Keychain 真实实现此处不测，Phase B 手动验证）。

- [ ] **Step 6: 提交**

```bash
git add Sources/UDIDRegisterKit/SecretStore.swift Sources/UDIDRegisterKit/AccountStore.swift Tests/UDIDRegisterKitTests/SecretStoreTests.swift Tests/UDIDRegisterKitTests/AccountStoreTests.swift
git commit -m "feat(kit): secret store (keychain/in-memory) and account store"
```

---

## Phase B — UDIDRegisterApp（SwiftUI，手动验证）

> UI 逻辑薄，核心已在 Kit 单测覆盖。这些任务用 `swift run UDIDRegisterApp` 启动手动验证；无自动化测试步骤，但每步给出明确的「预期看到」。

### Task 6: App 骨架（能起窗口）

**Files:**
- Create: `Sources/UDIDRegisterApp/UDIDRegisterApp.swift`
- Create: `Sources/UDIDRegisterApp/AppModel.swift`
- Create: `Sources/UDIDRegisterApp/RootView.swift`

**Interfaces:**
- Consumes: 全部 Kit 公有类型。
- Produces: `@Observable final class AppModel`（`accounts`, `selectedID`, `selected`, `quotaText`, `results:[RowResult]`, `registering`）；`struct RowResult: Identifiable`。

- [ ] **Step 1: 写 AppModel.swift（骨架 + 依赖注入）**

```swift
import Foundation
import UDIDRegisterKit

struct RowResult: Identifiable {
    let id = UUID()
    let name: String
    let udid: String
    let outcome: RegistrationOutcome
}

enum AppError: LocalizedError {
    case msg(String)
    var errorDescription: String? { if case let .msg(m) = self { return m }; return nil }
}

@MainActor
@Observable
final class AppModel {
    var accounts: [AppleAccount] = []
    var selectedID: UUID?
    var quotaText: String = ""
    var results: [RowResult] = []
    var registering = false
    var banner: String?

    let store: AccountStore
    let secrets: SecretStore
    let client: ASCClient

    init(store: AccountStore = AccountStore(fileURL: AccountStore.defaultFileURL()),
         secrets: SecretStore = KeychainSecretStore(),
         client: ASCClient = ASCClient(http: URLSessionHTTPClient())) {
        self.store = store; self.secrets = secrets; self.client = client
        reload()
    }
    func reload() {
        accounts = store.accounts
        if selectedID == nil || !accounts.contains(where: { $0.id == selectedID }) {
            selectedID = accounts.first?.id
        }
    }
    var selected: AppleAccount? { accounts.first { $0.id == selectedID } }

    func credentials(for a: AppleAccount) throws -> ASCCredentials {
        guard let pem = try secrets.load(for: a.id) else { throw AppError.msg("找不到该账号的 .p8，请重新添加") }
        return ASCCredentials(keyID: a.keyID, issuerID: a.issuerID, privateKeyPEM: pem)
    }
}
```

- [ ] **Step 2: 写 RootView.swift（占位）**

```swift
import SwiftUI
import UDIDRegisterKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 12) {
            Text("UDID 注册助手").font(.title2).bold()
            Text(model.accounts.isEmpty ? "还没有账号" : "账号数：\(model.accounts.count)")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 640, minHeight: 520)
    }
}
```

- [ ] **Step 3: 写 UDIDRegisterApp.swift（入口 + 激活策略）**

```swift
import SwiftUI
import AppKit

@main
struct UDIDRegisterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            RootView().environment(model)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)          // SPM 可执行需显式设为常规 app 才有 Dock 图标/前台窗口
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
```

- [ ] **Step 4: 构建并运行，手动验证**

Run: `swift run UDIDRegisterApp`
Expected: 弹出一个窗口，标题「UDID 注册助手」，下面显示「还没有账号」。关闭窗口进程退出。

- [ ] **Step 5: 提交**

```bash
git add Sources/UDIDRegisterApp/
git commit -m "feat(app): SwiftUI shell that launches a window"
```

---

### Task 7: 账号管理（增删改 + 测试连接）

**Files:**
- Create: `Sources/UDIDRegisterApp/AccountManagerView.swift`
- Modify: `Sources/UDIDRegisterApp/AppModel.swift`（加账号编辑与测试连接方法）
- Modify: `Sources/UDIDRegisterApp/RootView.swift`（加「管理账号…」入口 + 账号选择器）

**Interfaces:**
- Consumes: `AppModel`、`ASCClient.listDevices`、`SecretStore`、`AccountStore`。
- Produces: `AppModel.addAccount(displayName:keyID:issuerID:teamID:p8PEM:) async -> Bool`；`AppModel.deleteAccount(id:)`；`AppModel.testConnection(for:) async -> Result<Int,Error>`。

- [ ] **Step 1: 往 AppModel.swift 追加方法**

```swift
extension AppModel {
    /// 校验凭据（签 JWT + 拉一页设备），成功则存账号 + 存 .p8 到 Keychain。
    func addAccount(displayName: String, keyID: String, issuerID: String,
                    teamID: String?, p8PEM: String) async -> Bool {
        let account = AppleAccount(displayName: displayName, keyID: keyID, issuerID: issuerID, teamID: teamID)
        let cred = ASCCredentials(keyID: keyID, issuerID: issuerID, privateKeyPEM: p8PEM)
        do {
            _ = try await client.listDevices(credentials: cred)   // 凭据有效性校验
            try secrets.save(p8PEM, for: account.id)
            try store.add(account)
            reload()
            selectedID = account.id
            banner = nil
            return true
        } catch {
            banner = "凭据校验失败：\(error.localizedDescription)"
            return false
        }
    }
    func deleteAccount(id: UUID) {
        try? secrets.delete(for: id)
        try? store.remove(id: id)
        reload()
    }
    /// 返回设备数（额度已用）或错误
    func testConnection(for a: AppleAccount) async -> Result<Int, Error> {
        do {
            let cred = try credentials(for: a)
            let rows = try await client.listDevices(credentials: cred)
            return .success(rows.count)
        } catch { return .failure(error) }
    }
}
```

- [ ] **Step 2: 写 AccountManagerView.swift**

```swift
import SwiftUI
import UniformTypeIdentifiers
import UDIDRegisterKit

struct AccountManagerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var keyID = ""
    @State private var issuerID = ""
    @State private var teamID = ""
    @State private var p8PEM = ""
    @State private var p8Filename = ""
    @State private var busy = false
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("账号管理").font(.headline)

            if !model.accounts.isEmpty {
                List {
                    ForEach(model.accounts) { a in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(a.displayName).bold()
                                Text("Key \(a.keyID) · Issuer \(a.issuerID.prefix(8))…")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { model.deleteAccount(id: a.id) } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.borderless)
                        }
                    }
                }.frame(height: 140)
            }

            Divider()
            Text("添加账号").font(.subheadline).bold()
            TextField("显示名（如 jgz / 公司A）", text: $displayName)
            TextField("Key ID（如 QA2MC7L8X7）", text: $keyID)
            TextField("Issuer ID（UUID）", text: $issuerID)
            TextField("Team ID（可选，仅展示）", text: $teamID)

            HStack {
                Button("选择 .p8 文件…") { importing = true }
                Text(p8Filename.isEmpty ? "未选择" : p8Filename)
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let banner = model.banner {
                Text(banner).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                Button(busy ? "校验中…" : "添加并校验") {
                    Task {
                        busy = true
                        let ok = await model.addAccount(displayName: displayName, keyID: keyID,
                            issuerID: issuerID, teamID: teamID.isEmpty ? nil : teamID, p8PEM: p8PEM)
                        busy = false
                        if ok { displayName = ""; keyID = ""; issuerID = ""; teamID = ""; p8PEM = ""; p8Filename = "" }
                    }
                }
                .disabled(busy || displayName.isEmpty || keyID.isEmpty || issuerID.isEmpty || p8PEM.isEmpty)
            }
        }
        .padding()
        .frame(width: 460)
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data]) { result in
            if case let .success(url) = result {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    p8PEM = text; p8Filename = url.lastPathComponent
                }
            }
        }
    }
}
```

- [ ] **Step 3: 往 RootView.swift 加选择器 + 入口**

```swift
import SwiftUI
import UDIDRegisterKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showAccounts = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("账号").font(.subheadline)
                Picker("账号", selection: $model.selectedID) {
                    ForEach(model.accounts) { a in Text(a.displayName).tag(Optional(a.id)) }
                }
                .labelsHidden().frame(maxWidth: 220)
                Button("管理账号…") { showAccounts = true }
                Spacer()
            }
            if model.selected == nil {
                Text("请先添加一个苹果账号").foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 520)
        .sheet(isPresented: $showAccounts) { AccountManagerView().environment(model) }
    }
}
```

- [ ] **Step 4: 运行并手动验证**

Run: `swift run UDIDRegisterApp`
Steps: 点「管理账号…」→ 填显示名/Key ID/Issuer ID → 选一个真实 `.p8` → 点「添加并校验」。
Expected: 校验成功后账号出现在列表、顶部选择器出现该账号；用错误 Key ID 则显示红色「凭据校验失败…」。

- [ ] **Step 5: 提交**

```bash
git add Sources/UDIDRegisterApp/
git commit -m "feat(app): account management with .p8 import and credential check"
```

---

### Task 8: UDID 批量录入 + 注册 + 结果

**Files:**
- Create: `Sources/UDIDRegisterApp/StatusText.swift`
- Create: `Sources/UDIDRegisterApp/RegisterView.swift`
- Modify: `Sources/UDIDRegisterApp/AppModel.swift`（加 `register(text:)`）
- Modify: `Sources/UDIDRegisterApp/RootView.swift`（嵌入 RegisterView）

**Interfaces:**
- Consumes: `DeviceInputParser.parse`、`UDIDNormalizer.normalize`、`ASCClient.registerDevice`。
- Produces: `AppModel.register(text:) async`；`func outcomeText(_:) -> String`；`func statusText(_:) -> String`。

- [ ] **Step 1: 写 StatusText.swift**

```swift
import UDIDRegisterKit

func statusText(_ s: DeviceStatus) -> String {
    switch s {
    case .enabled:    return "✅ 已可用 — 可直接用于真机调试/打包"
    case .processing: return "⏳ 处理中 — 苹果正在处理，可能需 24~72 小时才可供开发使用"
    case .disabled:   return "🚫 已禁用 — 仍占用 100 台/年额度"
    case .unknown:    return "ℹ️ 未知状态"
    }
}

func outcomeText(_ o: RegistrationOutcome) -> String {
    switch o {
    case .created(let s):                 return "✅ 注册成功 · \(statusText(s))"
    case .alreadyExisted(let name, let s): return "ℹ️ 已存在（苹果记录名：\(name)） · \(statusText(s))"
    case .failed(let m):                  return "❌ \(m)"
    }
}
```

- [ ] **Step 2: 往 AppModel.swift 加 register(text:)**

```swift
extension AppModel {
    func register(text: String) async {
        guard let a = selected else { banner = "请先选择账号"; return }
        let cred: ASCCredentials
        do { cred = try credentials(for: a) }
        catch { banner = error.localizedDescription; return }

        registering = true
        results = []
        banner = nil
        for input in DeviceInputParser.parse(text) {
            guard let udid = UDIDNormalizer.normalize(input.udidRaw) else {
                results.append(RowResult(name: input.name, udid: input.udidRaw,
                                         outcome: .failed(message: "UDID 格式不正确")))
                continue
            }
            do {
                let outcome = try await client.registerDevice(credentials: cred, name: input.name, udid: udid)
                results.append(RowResult(name: input.name, udid: udid, outcome: outcome))
            } catch {
                results.append(RowResult(name: input.name, udid: udid,
                                         outcome: .failed(message: error.localizedDescription)))
            }
        }
        registering = false
    }
}
```

- [ ] **Step 3: 写 RegisterView.swift**

```swift
import SwiftUI
import UDIDRegisterKit

struct RegisterView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("批量录入（每行一条，格式 UDID 或 UDID,名称）").font(.subheadline)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack {
                Spacer()
                Button(model.registering ? "注册中…" : "注册全部") {
                    Task { await model.register(text: text) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.registering || model.selected == nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !model.results.isEmpty {
                Divider()
                Text("结果").font(.subheadline).bold()
                List(model.results) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(r.name)  ·  \(r.udid)").font(.caption).foregroundStyle(.secondary)
                        Text(outcomeText(r.outcome))
                    }
                }.frame(minHeight: 160)
            }
        }
    }
}
```

- [ ] **Step 4: 往 RootView.swift 嵌入 RegisterView**

在 `if model.selected == nil { … }` 之后、`.padding()` 之前插入：

```swift
            if model.selected != nil {
                Divider()
                RegisterView().environment(model)
            }
```

- [ ] **Step 5: 运行并手动验证**

Run: `swift run UDIDRegisterApp`
Steps: 选中账号 → 录入框粘贴一行 `<真实UDID>, 测试机A` → 点「注册全部」。
Expected: 结果区出现一行，显示 `✅ 注册成功 · …` 或 `ℹ️ 已存在（…） · …`；粘贴一个错误 UDID 则显示 `❌ UDID 格式不正确`。

- [ ] **Step 6: 提交**

```bash
git add Sources/UDIDRegisterApp/
git commit -m "feat(app): batch UDID entry, registration and result list"
```

---

### Task 9: 额度视图 + 选中账号持久化 + 收尾

**Files:**
- Modify: `Sources/UDIDRegisterApp/AppModel.swift`（`refreshQuota`、选中持久化、注册后刷新）
- Modify: `Sources/UDIDRegisterApp/RootView.swift`（显示额度）

**Interfaces:**
- Produces: `AppModel.refreshQuota() async`；`quotaText` 形如 `已用 48 / 100 台`。选中账号 id 存 `UserDefaults` key `selectedAccountID`。

- [ ] **Step 1: 往 AppModel.swift 加额度与持久化**

```swift
extension AppModel {
    private static let selKey = "selectedAccountID"

    func restoreSelection() {
        if let s = UserDefaults.standard.string(forKey: Self.selKey), let id = UUID(uuidString: s),
           accounts.contains(where: { $0.id == id }) {
            selectedID = id
        }
    }
    func persistSelection() {
        UserDefaults.standard.set(selectedID?.uuidString, forKey: Self.selKey)
    }
    func refreshQuota() async {
        guard let a = selected else { quotaText = ""; return }
        do {
            let rows = try await client.listDevices(credentials: try credentials(for: a))
            quotaText = "已用 \(rows.count) / 100 台"
        } catch {
            quotaText = "额度获取失败"
        }
    }
}
```

- [ ] **Step 2: register(text:) 末尾追加刷新**

在 Task 8 的 `registering = false` 之后加一行：

```swift
        await refreshQuota()
```

- [ ] **Step 3: RootView.swift 显示额度 + 切换时刷新 + 启动恢复**

在账号 HStack 的 `Spacer()` 后加额度文本：

```swift
                if !model.quotaText.isEmpty {
                    Text(model.quotaText).font(.caption).foregroundStyle(.secondary)
                }
```

在 `VStack` 上加生命周期钩子（放到 `.sheet` 之后）：

```swift
        .task { model.restoreSelection(); await model.refreshQuota() }
        .onChange(of: model.selectedID) { _, _ in
            model.persistSelection()
            Task { await model.refreshQuota() }
        }
```

- [ ] **Step 4: 运行并手动验证**

Run: `swift run UDIDRegisterApp`
Expected: 顶部显示「已用 X / 100 台」；切换账号后数字随之变化；注册成功后数字 +1；重启 app 后仍停在上次选的账号。

- [ ] **Step 5: 提交**

```bash
git add Sources/UDIDRegisterApp/
git commit -m "feat(app): quota display and selected-account persistence"
```

---

## Phase C — 打包分发

### Task 10: 签名 + 公证 + DMG 脚本

**Files:**
- Create: `scripts/package.sh`
- Create: `Resources/UDIDRegisterMac.entitlements`
- Create: `README.md`

**Interfaces:** 无代码接口；产出可分发的已公证 DMG。

- [ ] **Step 1: 写 entitlements（Resources/UDIDRegisterMac.entitlements）**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.network.client</key><true/>
    <key>com.apple.security.files.user-selected.read-only</key><true/>
</dict>
</plist>
```

- [ ] **Step 2: 写 package.sh（构建 → .app 包 → 签名 → 公证 → DMG）**

```bash
#!/usr/bin/env bash
set -euo pipefail
# 需要环境变量：DEV_ID_APP="Developer ID Application: NAME (TEAMID)"，NOTARY_PROFILE=公证 keychain profile 名
APP="UDIDRegisterMac.app"
BIN="UDIDRegisterApp"
DIST="dist"

swift build -c release --product "$BIN"

rm -rf "$DIST/$APP"; mkdir -p "$DIST/$APP/Contents/MacOS" "$DIST/$APP/Contents/Resources"
cp ".build/release/$BIN" "$DIST/$APP/Contents/MacOS/$BIN"

cat > "$DIST/$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>UDID 注册助手</string>
<key>CFBundleIdentifier</key><string>com.yourco.UDIDRegisterMac</string>
<key>CFBundleExecutable</key><string>$BIN</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST

codesign --force --options runtime --timestamp \
  --entitlements Resources/UDIDRegisterMac.entitlements \
  --sign "$DEV_ID_APP" "$DIST/$APP"

hdiutil create -volname "UDID 注册助手" -srcfolder "$DIST/$APP" -ov -format UDZO "$DIST/UDIDRegisterMac.dmg"

xcrun notarytool submit "$DIST/UDIDRegisterMac.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DIST/UDIDRegisterMac.dmg"
echo "✅ 完成：$DIST/UDIDRegisterMac.dmg"
```

- [ ] **Step 3: 写 README.md**

写清：这是什么、`swift test` 跑单测、`swift run UDIDRegisterApp` 本地运行、`bash scripts/package.sh` 打包（需先 `xcrun notarytool store-credentials` 配好 profile、设 `DEV_ID_APP` / `NOTARY_PROFILE`）、以及「.p8 只存本机 Keychain」的安全说明。`bundle id` `com.yourco.UDIDRegisterMac` 需替换为你的真实前缀，并与 `KeychainSecretStore(service:)` 保持一致。

- [ ] **Step 4: 手动验证打包（有开发者签名证书时）**

Run: `chmod +x scripts/package.sh && DEV_ID_APP="Developer ID Application: … (TEAMID)" NOTARY_PROFILE=your-profile bash scripts/package.sh`
Expected: 生成 `dist/UDIDRegisterMac.dmg`，`notarytool` 返回 `Accepted`，`stapler` 成功。双击 DMG 拖出的 app 能正常启动、加账号、注册。

- [ ] **Step 5: 提交**

```bash
git add scripts/package.sh Resources/UDIDRegisterMac.entitlements README.md
git commit -m "chore: sign + notarize + dmg packaging script and docs"
```

---

## Self-Review（对照 spec）

**Spec 覆盖：**
- 账号管理（选 .p8/Issuer/Key ID、Team ID 可选、测试连接）→ Task 5（存储）+ Task 7（UI + 校验）✅
- UDID 单条/批量录入 + 规范化 → Task 1（normalize）+ Task 2（parser）+ Task 8（UI）✅
- 注册 + 状态（201/409 回查/文案 24–72h）→ Task 4（逻辑）+ Task 8（文案/结果）✅
- 额度「已用 X/100」→ Task 9 ✅
- JWT ES256 + iat 回拨 30s → Task 3 ✅
- Keychain 存 .p8、不落盘 → Task 5 + Task 7（导入即存 Keychain，PEM 不写文件）✅
- 测试策略（normalize/JWT/client mock）→ Task 1–5 XCTest ✅
- Developer ID 签名 + 公证 DMG → Task 10 ✅
- 新 repo 结构 → 本计划文件结构一致 ✅
- 非目标（授权/隧道/云/删除）→ 计划中均未引入 ✅

**占位符扫描：** 无 TBD/TODO；每步含实际代码或明确命令与预期。

**类型一致性：** `AppModel` 方法（addAccount/deleteAccount/testConnection/register/refreshQuota/restoreSelection/persistSelection）跨 Task 6–9 命名一致；`ASCClient.registerDevice/listDevices`、`RegistrationOutcome` 三态、`DeviceStatus` 枚举在 Kit 与 App 间一致。
