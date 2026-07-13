# UDID 注册助手 — 分发打磨实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把现有 UDID 注册 Mac app 打磨到可安心发给同事：修发布阻塞项、加一键配置文件导入导出、友好中文报错、图标、使用说明。

**Architecture:** 沿用现有两层结构——纯逻辑放 `UDIDRegisterKit`（TDD，`swift test` 覆盖），SwiftUI 层 `UDIDRegisterApp` 是薄壳（`swift build` + 手动验证）。本轮不引入后端、不加第三方依赖。新增的编解码与错误映射都落在 Kit 层以便测试；UI 只做胶水。

**Tech Stack:** Swift 5.9 / SwiftUI + AppKit / CryptoKit / Security（Keychain）/ Swift Package Manager，零第三方依赖，macOS 14+。

## Global Constraints

- **Bundle ID 唯一真值**：`com.pangu.UDIDRegisterMac`，定义在 `Sources/UDIDRegisterKit/AppIdentifiers.swift`，其它地方（Keychain service、打包 Info.plist）都从这里取，不得再硬编码副本。
- **所有面向用户的字符串一律中文。**
- **平台/工具**：macOS 14+、Swift 5.9、SPM，禁止引入第三方依赖。
- **测试策略**：Kit 层新增逻辑走 TDD（`swift test`）；App/脚本层用 `swift build` + 手动端到端验证。
- **凭据下发模型**：`.udidconfig` 是明文 JSON 含私钥，属既定选择；靠文档提示安全传输，不加额外加密。
- **每个 Task 结束都要 commit。**

---

### Task 1: Bundle ID 单一来源

**Files:**
- Create: `Sources/UDIDRegisterKit/AppIdentifiers.swift`
- Modify: `Sources/UDIDRegisterKit/SecretStore.swift:22`
- Test: `Tests/UDIDRegisterKitTests/AppIdentifiersTests.swift`

**Interfaces:**
- Produces: `enum AppIdentifiers { public static let bundleID: String }`（值 `"com.pangu.UDIDRegisterMac"`）；`KeychainSecretStore` 默认 `service` 改为 `AppIdentifiers.bundleID`。

- [ ] **Step 1: 写失败测试**

`Tests/UDIDRegisterKitTests/AppIdentifiersTests.swift`：
```swift
import XCTest
@testable import UDIDRegisterKit

final class AppIdentifiersTests: XCTestCase {
    func testBundleIDValue() {
        XCTAssertEqual(AppIdentifiers.bundleID, "com.pangu.UDIDRegisterMac")
    }
    func testKeychainStoreUsesBundleIDByDefault() {
        XCTAssertEqual(KeychainSecretStore().service, AppIdentifiers.bundleID)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter AppIdentifiersTests`
Expected: 编译失败（`AppIdentifiers` 未定义）。

- [ ] **Step 3: 新增常量**

`Sources/UDIDRegisterKit/AppIdentifiers.swift`：
```swift
import Foundation

/// App 全局标识符的唯一真值来源。
/// 注意：打包脚本 scripts/package.sh 会从本文件抽取 bundleID 写入 Info.plist，
/// 必须与 Keychain service 保持一致，否则打包版读不出已存的凭据。
public enum AppIdentifiers {
    public static let bundleID = "com.pangu.UDIDRegisterMac"
}
```

- [ ] **Step 4: 让 Keychain 默认 service 用该常量**

`Sources/UDIDRegisterKit/SecretStore.swift:22`，把：
```swift
    public init(service: String = "com.yourco.UDIDRegisterMac") { self.service = service }
```
改为：
```swift
    public init(service: String = AppIdentifiers.bundleID) { self.service = service }
```

- [ ] **Step 5: 运行测试确认通过**

Run: `swift test --filter AppIdentifiersTests`
Expected: PASS（2 个测试）。

- [ ] **Step 6: Commit**

```bash
git add Sources/UDIDRegisterKit/AppIdentifiers.swift Sources/UDIDRegisterKit/SecretStore.swift Tests/UDIDRegisterKitTests/AppIdentifiersTests.swift
git commit -m "feat(kit): single-source bundle id via AppIdentifiers"
```

---

### Task 2: 配置文件模型与编解码（AccountConfig）

**Files:**
- Create: `Sources/UDIDRegisterKit/AccountConfig.swift`
- Test: `Tests/UDIDRegisterKitTests/AccountConfigTests.swift`

**Interfaces:**
- Produces:
  - `struct AccountConfig: Codable, Equatable`，字段 `schemaVersion: Int, displayName: String, keyID: String, issuerID: String, teamID: String?, p8PEM: String`。
  - `enum AccountConfigError: Error, LocalizedError { case unsupportedVersion(Int); case malformed }`。
  - `enum AccountConfigCodec { static let currentVersion = 1; static func encode(_:) throws -> Data; static func decode(_:) throws -> AccountConfig }`。

- [ ] **Step 1: 写失败测试**

`Tests/UDIDRegisterKitTests/AccountConfigTests.swift`：
```swift
import XCTest
@testable import UDIDRegisterKit

final class AccountConfigTests: XCTestCase {
    private func sample() -> AccountConfig {
        AccountConfig(schemaVersion: 1, displayName: "公司主账号", keyID: "QA2MC7L8X7",
                      issuerID: "11111111-2222-3333-4444-555555555555", teamID: "ABCDE12345",
                      p8PEM: "-----BEGIN PRIVATE KEY-----\nMFAKE\n-----END PRIVATE KEY-----\n")
    }
    func testRoundTrip() throws {
        let data = try AccountConfigCodec.encode(sample())
        XCTAssertEqual(try AccountConfigCodec.decode(data), sample())
    }
    func testNilTeamIDRoundTrips() throws {
        var c = sample(); c.teamID = nil
        let data = try AccountConfigCodec.encode(c)
        XCTAssertEqual(try AccountConfigCodec.decode(data), c)
    }
    func testUnsupportedVersion() throws {
        var c = sample(); c.schemaVersion = 2
        let data = try AccountConfigCodec.encode(c)
        XCTAssertThrowsError(try AccountConfigCodec.decode(data)) {
            guard case AccountConfigError.unsupportedVersion(2) = $0 else { return XCTFail("wrong error: \($0)") }
        }
    }
    func testMalformedJSON() {
        XCTAssertThrowsError(try AccountConfigCodec.decode(Data("not json".utf8))) {
            guard case AccountConfigError.malformed = $0 else { return XCTFail("wrong error: \($0)") }
        }
    }
    func testMissingFieldIsMalformed() {
        let json = #"{"schemaVersion":1,"displayName":"x","issuerID":"y","p8PEM":"-----BEGIN PRIVATE KEY-----"}"#
        XCTAssertThrowsError(try AccountConfigCodec.decode(Data(json.utf8))) {
            guard case AccountConfigError.malformed = $0 else { return XCTFail("wrong error: \($0)") }
        }
    }
    func testEmptyPEMIsMalformed() throws {
        var c = sample(); c.p8PEM = ""
        let data = try AccountConfigCodec.encode(c)
        XCTAssertThrowsError(try AccountConfigCodec.decode(data)) {
            guard case AccountConfigError.malformed = $0 else { return XCTFail("wrong error: \($0)") }
        }
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter AccountConfigTests`
Expected: 编译失败（`AccountConfig` 等未定义）。

- [ ] **Step 3: 实现模型与编解码**

`Sources/UDIDRegisterKit/AccountConfig.swift`：
```swift
import Foundation

/// 一键配置文件（.udidconfig）的内容。含私钥，仅经安全渠道分发。
public struct AccountConfig: Codable, Equatable {
    public var schemaVersion: Int
    public var displayName: String
    public var keyID: String
    public var issuerID: String
    public var teamID: String?
    public var p8PEM: String
    public init(schemaVersion: Int, displayName: String, keyID: String,
                issuerID: String, teamID: String?, p8PEM: String) {
        self.schemaVersion = schemaVersion; self.displayName = displayName
        self.keyID = keyID; self.issuerID = issuerID; self.teamID = teamID; self.p8PEM = p8PEM
    }
}

public enum AccountConfigError: Error, LocalizedError {
    case unsupportedVersion(Int)
    case malformed
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return "配置文件版本不支持（version \(v)），请让管理员用新版重新导出"
        case .malformed:
            return "配置文件格式不正确，无法读取，请让管理员重新导出"
        }
    }
}

public enum AccountConfigCodec {
    public static let currentVersion = 1

    public static func encode(_ config: AccountConfig) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(config)
    }

    public static func decode(_ data: Data) throws -> AccountConfig {
        let config: AccountConfig
        do { config = try JSONDecoder().decode(AccountConfig.self, from: data) }
        catch { throw AccountConfigError.malformed }
        guard config.schemaVersion == currentVersion else {
            throw AccountConfigError.unsupportedVersion(config.schemaVersion)
        }
        guard !config.displayName.isEmpty, !config.keyID.isEmpty, !config.issuerID.isEmpty,
              config.p8PEM.contains("PRIVATE KEY") else {
            throw AccountConfigError.malformed
        }
        return config
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --filter AccountConfigTests`
Expected: PASS（6 个测试）。

- [ ] **Step 5: Commit**

```bash
git add Sources/UDIDRegisterKit/AccountConfig.swift Tests/UDIDRegisterKitTests/AccountConfigTests.swift
git commit -m "feat(kit): AccountConfig model + codec for .udidconfig"
```

---

### Task 3: 友好中文报错映射（UserFacingMessage）

**Files:**
- Create: `Sources/UDIDRegisterKit/UserFacingMessage.swift`
- Modify: `Sources/UDIDRegisterKit/ASCJWT.swift:4`
- Test: `Tests/UDIDRegisterKitTests/UserFacingMessageTests.swift`

**Interfaces:**
- Produces: `enum UserFacingMessage { static func from(_ error: Error) -> String }`；`ASCJWTError` 增加 `LocalizedError` 中文描述。

- [ ] **Step 1: 写失败测试**

`Tests/UDIDRegisterKitTests/UserFacingMessageTests.swift`：
```swift
import XCTest
@testable import UDIDRegisterKit

final class UserFacingMessageTests: XCTestCase {
    func testAuth401() {
        XCTAssertEqual(UserFacingMessage.from(ASCError.http(401, "x")),
                       "凭据无效或已过期，请检查 Key ID / Issuer ID / .p8 是否正确")
    }
    func testAuth403() {
        XCTAssertEqual(UserFacingMessage.from(ASCError.http(403, "")),
                       "凭据无效或已过期，请检查 Key ID / Issuer ID / .p8 是否正确")
    }
    func testOtherHTTPKeepsDetail() {
        XCTAssertEqual(UserFacingMessage.from(ASCError.http(500, "boom")), "请求失败：boom")
    }
    func testOtherHTTPNoDetail() {
        XCTAssertEqual(UserFacingMessage.from(ASCError.http(500, "")), "请求失败（ASC API 500）")
    }
    func testInvalidPrivateKey() {
        XCTAssertEqual(UserFacingMessage.from(ASCJWTError.invalidPrivateKey),
                       "这个 .p8 文件无法识别，请确认是从 App Store Connect 下载的原始 .p8 文件")
    }
    func testNetwork() {
        XCTAssertEqual(UserFacingMessage.from(URLError(.notConnectedToInternet)),
                       "网络连接失败，请检查网络后重试")
    }
    func testKeychain() {
        XCTAssertEqual(UserFacingMessage.from(KeychainError.os(-25300)),
                       "本机凭据存取失败（Keychain 错误码 -25300）")
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter UserFacingMessageTests`
Expected: 编译失败（`UserFacingMessage` 未定义）。

- [ ] **Step 3: 给 ASCJWTError 补中文描述**

`Sources/UDIDRegisterKit/ASCJWT.swift:4`，把：
```swift
public enum ASCJWTError: Error { case invalidPrivateKey }
```
改为：
```swift
public enum ASCJWTError: Error, LocalizedError {
    case invalidPrivateKey
    public var errorDescription: String? {
        "这个 .p8 文件无法识别，请确认是从 App Store Connect 下载的原始 .p8 文件"
    }
}
```

- [ ] **Step 4: 实现映射**

`Sources/UDIDRegisterKit/UserFacingMessage.swift`：
```swift
import Foundation

/// 把内部错误翻成面向非技术同事的中文提示。
public enum UserFacingMessage {
    public static func from(_ error: Error) -> String {
        switch error {
        case let ascError as ASCError:
            if case let .http(status, detail) = ascError {
                if status == 401 || status == 403 {
                    return "凭据无效或已过期，请检查 Key ID / Issuer ID / .p8 是否正确"
                }
                return detail.isEmpty ? "请求失败（ASC API \(status)）" : "请求失败：\(detail)"
            }
            return ascError.localizedDescription
        case ASCJWTError.invalidPrivateKey:
            return "这个 .p8 文件无法识别，请确认是从 App Store Connect 下载的原始 .p8 文件"
        case is URLError:
            return "网络连接失败，请检查网络后重试"
        case let keychainError as KeychainError:
            if case let .os(status) = keychainError {
                return "本机凭据存取失败（Keychain 错误码 \(status)）"
            }
            return "本机凭据存取失败"
        default:
            return error.localizedDescription
        }
    }
}
```

- [ ] **Step 5: 运行测试确认通过**

Run: `swift test --filter UserFacingMessageTests`
Expected: PASS（7 个测试）。

- [ ] **Step 6: 跑全量测试确认没打破旧测试**

Run: `swift test`
Expected: 全绿（含既有 ~19 个测试 + 本轮新增）。

- [ ] **Step 7: Commit**

```bash
git add Sources/UDIDRegisterKit/UserFacingMessage.swift Sources/UDIDRegisterKit/ASCJWT.swift Tests/UDIDRegisterKitTests/UserFacingMessageTests.swift
git commit -m "feat(kit): user-facing Chinese error mapping"
```

---

### Task 4: 生成 App 图标

**Files:**
- Create: `scripts/make-icon.swift`
- Create（脚本产物）: `Resources/AppIcon.icns`
- Modify: `.gitignore`（忽略中间产物 `Resources/AppIcon.iconset/`）

**Interfaces:**
- Produces: `Resources/AppIcon.icns`（供 Task 5 的 package.sh 拷入 bundle）。

- [ ] **Step 1: 写图标生成脚本**

`scripts/make-icon.swift`：
```swift
#!/usr/bin/env swift
import AppKit

func render(px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    let ctx = gctx.cgContext

    // 背景：圆角矩形 + 蓝紫渐变
    let bg = CGRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s*0.05, dy: s*0.05)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: bg, cornerWidth: s*0.225, cornerHeight: s*0.225, transform: nil))
    ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(red: 0.31, green: 0.40, blue: 0.96, alpha: 1),
                 CGColor(red: 0.58, green: 0.31, blue: 0.93, alpha: 1)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: bg.minX, y: bg.maxY),
                           end: CGPoint(x: bg.maxX, y: bg.minY), options: [])
    ctx.restoreGState()

    // 手机机身：白色圆角矩形
    let pw = s*0.34, ph = s*0.56, pcx = s*0.46, pcy = s*0.52
    let phone = CGRect(x: pcx - pw/2, y: pcy - ph/2, width: pw, height: ph)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(CGPath(roundedRect: phone, cornerWidth: s*0.07, cornerHeight: s*0.07, transform: nil))
    ctx.fillPath()

    // 屏幕：浅灰
    let screen = phone.insetBy(dx: s*0.03, dy: s*0.05)
    ctx.setFillColor(CGColor(red: 0.90, green: 0.92, blue: 0.96, alpha: 1))
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: s*0.04, cornerHeight: s*0.04, transform: nil))
    ctx.fillPath()

    // 绿色对勾徽章：右下角圆
    let br = s*0.15, bcx = phone.maxX - s*0.02, bcy = phone.minY + s*0.04
    let badge = CGRect(x: bcx - br, y: bcy - br, width: br*2, height: br*2)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(s*0.02)
    ctx.strokeEllipse(in: badge.insetBy(dx: -s*0.012, dy: -s*0.012))
    ctx.setFillColor(CGColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1))
    ctx.fillEllipse(in: badge)

    // 白色对勾
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(s*0.028); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: bcx - br*0.45, y: bcy + br*0.02))
    ctx.addLine(to: CGPoint(x: bcx - br*0.10, y: bcy - br*0.35))
    ctx.addLine(to: CGPoint(x: bcx + br*0.50, y: bcy + br*0.35))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = "Resources/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
let items: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)]
for (name, px) in items {
    try! render(px: px).write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "✅ Resources/AppIcon.icns 生成成功" : "❌ iconutil 失败")
```

- [ ] **Step 2: 运行脚本生成图标**

Run: `swift scripts/make-icon.swift`
Expected: 打印 `✅ Resources/AppIcon.icns 生成成功`。

- [ ] **Step 3: 校验产物**

Run: `file Resources/AppIcon.icns`
Expected: 输出含 `Mac OS X icon`（或 `icns`）。可选人工看一眼：`open Resources/AppIcon.icns`。

- [ ] **Step 4: 忽略中间产物**

在 `.gitignore` 末尾追加一行：
```
Resources/AppIcon.iconset/
```

- [ ] **Step 5: Commit**

```bash
git add scripts/make-icon.swift Resources/AppIcon.icns .gitignore
git commit -m "feat(app): generate app icon (device + check badge)"
```

---

### Task 5: 仓库内 Info.plist + 打包脚本单源化 + 图标 + 写权限

**Files:**
- Create: `Resources/Info.plist`
- Modify: `Resources/UDIDRegisterMac.entitlements:7`
- Modify: `scripts/package.sh`（替换内联 Info.plist，改为复制文件 + 单源 bundle-id + 拷图标）

**Interfaces:**
- Consumes: `AppIdentifiers.bundleID`（Task 1，脚本 grep 抽取）、`Resources/AppIcon.icns`（Task 4）。
- Produces: 打包出的 `.app` 带正确图标、bundle-id 与 Keychain service 一致、并具备用户选中文件的**读写**权限（导出配置需要写）。

- [ ] **Step 1: 新增静态 Info.plist**

`Resources/Info.plist`：
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>UDID 注册助手</string>
<key>CFBundleDisplayName</key><string>UDID 注册助手</string>
<key>CFBundleIdentifier</key><string>com.pangu.UDIDRegisterMac</string>
<key>CFBundleExecutable</key><string>UDIDRegisterApp</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
```

- [ ] **Step 2: 升级 entitlement 到读写**

`Resources/UDIDRegisterMac.entitlements:7`，把：
```xml
    <key>com.apple.security.files.user-selected.read-only</key><true/>
```
改为：
```xml
    <key>com.apple.security.files.user-selected.read-write</key><true/>
```
（导出 `.udidconfig` 要写用户选中的文件；导入只读也被读写权限覆盖。）

- [ ] **Step 3: 重写 package.sh**

`scripts/package.sh`（整份替换）：
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# 需要环境变量：DEV_ID_APP="Developer ID Application: NAME (TEAMID)"，NOTARY_PROFILE=公证 keychain profile 名
APP="UDIDRegisterMac.app"
BIN="UDIDRegisterApp"
DIST="dist"

# bundle-id 单一来源：从 AppIdentifiers.swift 抽取，保证与 Keychain service 一致
BUNDLE_ID=$(grep -Eo 'bundleID[[:space:]]*=[[:space:]]*"[^"]+"' Sources/UDIDRegisterKit/AppIdentifiers.swift | sed -E 's/.*"([^"]+)".*/\1/')
[ -n "$BUNDLE_ID" ] || { echo "❌ 无法从 AppIdentifiers.swift 解析 bundleID"; exit 1; }
echo "Bundle ID: $BUNDLE_ID"

[ -f Resources/AppIcon.icns ] || { echo "❌ 缺少 Resources/AppIcon.icns，请先运行 swift scripts/make-icon.swift"; exit 1; }

swift build -c release --product "$BIN"

rm -rf "$DIST/$APP"; mkdir -p "$DIST/$APP/Contents/MacOS" "$DIST/$APP/Contents/Resources"
cp ".build/release/$BIN" "$DIST/$APP/Contents/MacOS/$BIN"
cp Resources/AppIcon.icns "$DIST/$APP/Contents/Resources/AppIcon.icns"

cp Resources/Info.plist "$DIST/$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$DIST/$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $BIN" "$DIST/$APP/Contents/Info.plist"

codesign --force --options runtime --timestamp \
  --entitlements Resources/UDIDRegisterMac.entitlements \
  --sign "$DEV_ID_APP" "$DIST/$APP"

hdiutil create -volname "UDID 注册助手" -srcfolder "$DIST/$APP" -ov -format UDZO "$DIST/UDIDRegisterMac.dmg"

xcrun notarytool submit "$DIST/UDIDRegisterMac.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DIST/$APP"
xcrun stapler staple "$DIST/UDIDRegisterMac.dmg"
echo "✅ 完成：$DIST/UDIDRegisterMac.dmg"
```

- [ ] **Step 4: 无证书可做的验证**

Run:
```bash
plutil -lint Resources/Info.plist
grep -Eo 'bundleID[[:space:]]*=[[:space:]]*"[^"]+"' Sources/UDIDRegisterKit/AppIdentifiers.swift | sed -E 's/.*"([^"]+)".*/\1/'
```
Expected: 第一行输出 `Resources/Info.plist: OK`；第二行输出 `com.pangu.UDIDRegisterMac`。
（完整的签名/公证需要你的 `DEV_ID_APP` 证书，放到文末「最终手动验证」环节由你本人跑。）

- [ ] **Step 5: Commit**

```bash
git add Resources/Info.plist Resources/UDIDRegisterMac.entitlements scripts/package.sh
git commit -m "build: static Info.plist, single-source bundle id, icon + write entitlement"
```

---

### Task 6: AppModel 导出/导入配置 + 接入中文报错

**Files:**
- Modify: `Sources/UDIDRegisterApp/AppModel.swift`（新增 `exportConfig`/`importConfig`；把 banner 与失败行文案接入 `UserFacingMessage`）

**Interfaces:**
- Consumes: `AccountConfig` / `AccountConfigCodec`（Task 2）、`UserFacingMessage`（Task 3）、既有 `addAccount(displayName:keyID:issuerID:teamID:p8PEM:) async -> Bool`。
- Produces:
  - `func exportConfig(for a: AppleAccount) throws -> Data`
  - `func importConfig(from url: URL) async -> Bool`

- [ ] **Step 1: 新增导出/导入扩展**

在 `Sources/UDIDRegisterApp/AppModel.swift` 末尾追加：
```swift
extension AppModel {
    /// 读账号元数据 + 从 Keychain 取 .p8，打包成一键配置文件数据。
    func exportConfig(for a: AppleAccount) throws -> Data {
        guard let pem = try secrets.load(for: a.id) else {
            throw AppError.msg("找不到该账号的 .p8，无法导出，请重新添加账号")
        }
        let config = AccountConfig(schemaVersion: AccountConfigCodec.currentVersion,
                                   displayName: a.displayName, keyID: a.keyID,
                                   issuerID: a.issuerID, teamID: a.teamID, p8PEM: pem)
        return try AccountConfigCodec.encode(config)
    }

    /// 从一键配置文件导入：解析 → 复用 addAccount（含联网校验 + Keychain 写入 + 回滚）。
    func importConfig(from url: URL) async -> Bool {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { banner = "读取配置文件失败：\(UserFacingMessage.from(error))"; return false }
        let config: AccountConfig
        do { config = try AccountConfigCodec.decode(data) }
        catch { banner = UserFacingMessage.from(error); return false }
        return await addAccount(displayName: config.displayName, keyID: config.keyID,
                                issuerID: config.issuerID, teamID: config.teamID, p8PEM: config.p8PEM)
    }
}
```

- [ ] **Step 2: 把 addAccount 的报错接入 UserFacingMessage**

在 `Sources/UDIDRegisterApp/AppModel.swift` 的 `addAccount` 里，把：
```swift
        } catch {
            banner = "凭据校验失败：\(error.localizedDescription)"
            return false
        }
```
改为：
```swift
        } catch {
            banner = "凭据校验失败：\(UserFacingMessage.from(error))"
            return false
        }
```
并把：
```swift
        } catch {
            try? secrets.delete(for: account.id)
            banner = "保存失败：\(error.localizedDescription)"
            return false
        }
```
改为：
```swift
        } catch {
            try? secrets.delete(for: account.id)
            banner = "保存失败：\(UserFacingMessage.from(error))"
            return false
        }
```

- [ ] **Step 3: 把 register 的失败行接入 UserFacingMessage**

在 `Sources/UDIDRegisterApp/AppModel.swift` 的 `register(text:)` 里，把 credentials 取用的 catch：
```swift
        do { cred = try credentials(for: a) }
        catch { banner = error.localizedDescription; return }
```
改为：
```swift
        do { cred = try credentials(for: a) }
        catch { banner = UserFacingMessage.from(error); return }
```
并把逐台注册的 catch：
```swift
            } catch {
                results.append(RowResult(name: input.name, udid: udid,
                                         outcome: .failed(message: error.localizedDescription)))
            }
```
改为：
```swift
            } catch {
                results.append(RowResult(name: input.name, udid: udid,
                                         outcome: .failed(message: UserFacingMessage.from(error))))
            }
```

- [ ] **Step 4: 编译确认**

Run: `swift build`
Expected: 编译成功，无错误。

- [ ] **Step 5: Commit**

```bash
git add Sources/UDIDRegisterApp/AppModel.swift
git commit -m "feat(app): config export/import + wire Chinese error messages"
```

---

### Task 7: 账号管理界面 — 导入/导出按钮 + 删除二次确认

**Files:**
- Modify: `Sources/UDIDRegisterApp/AccountManagerView.swift`（整份替换）

**Interfaces:**
- Consumes: `model.exportConfig(for:)` / `model.importConfig(from:)`（Task 6）、`UserFacingMessage`（Task 3）、既有 `model.deleteAccount(id:)` / `model.addAccount(...)`。

- [ ] **Step 1: 替换 AccountManagerView**

`Sources/UDIDRegisterApp/AccountManagerView.swift`（整份替换）：
```swift
import SwiftUI
import AppKit
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
    @State private var importing = false          // 选 .p8
    @State private var configImporting = false    // 选 .udidconfig
    @State private var pendingDeleteID: UUID?
    @State private var showDeleteConfirm = false

    private var configTypes: [UTType] {
        [UTType(filenameExtension: "udidconfig") ?? .json, .json]
    }

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
                            Button("导出配置…") { exportAccount(a) }
                                .buttonStyle(.borderless)
                            Button(role: .destructive) {
                                pendingDeleteID = a.id; showDeleteConfirm = true
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                    }
                }.frame(height: 140)
            }

            Divider()
            HStack {
                Button("导入配置文件…") { configImporting = true }
                Text("同事一键配置：选择管理员给的 .udidconfig")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("配置文件含私钥，请通过安全渠道传递，用完可删除。")
                .font(.caption2).foregroundStyle(.secondary)

            Divider()
            Text("手动添加账号").font(.subheadline).bold()
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
        .fileImporter(isPresented: $configImporting, allowedContentTypes: configTypes) { result in
            if case let .success(url) = result {
                Task { busy = true; _ = await model.importConfig(from: url); busy = false }
            }
        }
        .alert("确定删除该账号？", isPresented: $showDeleteConfirm, presenting: pendingDeleteID) { id in
            Button("删除", role: .destructive) { model.deleteAccount(id: id) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("此操作会移除本机保存的凭据，无法撤销。")
        }
    }

    private func exportAccount(_ a: AppleAccount) {
        let data: Data
        do { data = try model.exportConfig(for: a) }
        catch { model.banner = UserFacingMessage.from(error); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(a.displayName).udidconfig"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do { try data.write(to: url); model.banner = nil }
            catch { model.banner = "导出失败：\(UserFacingMessage.from(error))" }
        }
    }
}
```

- [ ] **Step 2: 编译确认**

Run: `swift build`
Expected: 编译成功。

- [ ] **Step 3: 手动验证（跑起来点一遍）**

Run: `swift run UDIDRegisterApp`
手动走查（需要你手上有一份真实 Key ID / Issuer ID / .p8）：
1. 「管理账号…」→ 手动填三字段 + 选 .p8 → 「添加并校验」→ 账号出现在列表、顶部额度显示「已用 N / 100 台」。
2. 该账号行点「导出配置…」→ 存成 `X.udidconfig`。
3. 该账号行点垃圾桶 → 弹确认框 → 「删除」→ 账号消失。
4. 「导入配置文件…」→ 选刚导出的 `X.udidconfig` → 账号自动重新出现、被选中、额度刷新。
5. 断网后再点导入/注册 → 出现中文「网络连接失败，请检查网络后重试」。
Expected: 上述行为全部符合。

- [ ] **Step 4: Commit**

```bash
git add Sources/UDIDRegisterApp/AccountManagerView.swift
git commit -m "feat(app): config import/export UI + delete confirmation"
```

---

### Task 8: 同事使用说明 + README 分发小节

**Files:**
- Create: `docs/同事使用说明.md`
- Modify: `README.md`（新增「分发 / 给同事使用」小节，链到该文档）

**Interfaces:** 无代码接口。

- [ ] **Step 1: 写同事使用说明**

`docs/同事使用说明.md`：
```markdown
# UDID 注册助手 · 使用说明（给同事）

这是一个把测试设备（iPhone / iPad）的 UDID 注册进公司苹果开发者账号的小工具，注册后设备才能安装内测包。

## 一、第一次使用：导入配置

1. 找管理员要一个 `.udidconfig` 配置文件（里面已经含好凭据）。
2. 打开「UDID 注册助手」→ 点右上「管理账号…」。
3. 点「导入配置文件…」→ 选中那个 `.udidconfig`。
4. 稍等几秒联网校验，账号出现在列表、右上角显示「已用 N / 100 台」即成功。

> 配置文件含私钥，请妥善保管，用完可以删除；不要转发到公开群。

## 二、注册测试设备

1. 在主界面文本框里粘贴 UDID，一行一个。
   - 只写 UDID：`00008030-000A49...`
   - 带备注名：`00008030-000A49...,张三的iPhone`
2. 点「注册」。
3. 看每行结果：
   - ✅ 注册成功 — 新设备已加入。
   - ℹ️ 已存在 — 之前注册过，无需重复。
   - ❌ 失败 — 按提示处理（如「UDID 格式不正确」）。

> 新注册的设备，苹果侧可能需要 24~72 小时才可用于开发。

## 三、关于额度

- 每个开发者账号每年上限 **100 台**。
- 设备**停用后仍然占额度**，要到苹果的年度重置（续费成员资格时）才释放。
- 顶部「已用 N / 100 台」是当前用量。

## 四、UDID 从哪来？

- 用数据线把设备连到 Mac → 打开「访达 / Finder」→ 选中设备 → 点设备名下方的信息栏，会切换显示 UDID → 右键可拷贝。

## 五、常见问题

- **导入失败：网络连接失败** — 检查网络后重试。
- **导入失败：凭据无效或已过期** — 找管理员要新的 `.udidconfig`。
- **配置文件格式不正确** — 文件可能损坏，找管理员重新导出。
```

- [ ] **Step 2: 在 README 增加分发小节**

在 `README.md` 末尾追加：
```markdown
## 分发 / 给同事使用

本工具采用「凭据本地下发」模型：由管理员在自己机器上添加好账号后，用
「管理账号… → 导出配置…」导出一个 `.udidconfig` 文件，通过安全渠道发给同事；
同事在「管理账号… → 导入配置文件…」一键导入即可，无需手填 Key ID / Issuer ID。

- 面向同事的图文步骤见 [docs/同事使用说明.md](docs/同事使用说明.md)。
- `.udidconfig` 是明文 JSON 且**包含私钥**，等同于把账号的设备管理密钥分发出去；
  请只发给可信同事、走安全渠道、用完删除；密钥若泄漏需在 App Store Connect 作废并重新导出配置。
- 打包分发（签名 + 公证 + DMG）见上文打包小节；打包前需先运行
  `swift scripts/make-icon.swift` 生成图标。
```

- [ ] **Step 3: Commit**

```bash
git add docs/同事使用说明.md README.md
git commit -m "docs: colleague usage guide + README distribution section"
```

---

## 最终手动验证（由你本人跑，需要证书）

以下步骤需要你的 `DEV_ID_APP` 证书和 `NOTARY_PROFILE`，不在自动化范围内：

1. `swift test` — 全绿。
2. `swift scripts/make-icon.swift` — 生成图标。
3. `export DEV_ID_APP="Developer ID Application: … (TEAMID)"; export NOTARY_PROFILE="…"; ./scripts/package.sh` — 产出 `dist/UDIDRegisterMac.dmg`。
4. 打开 DMG 里的 app：确认**有图标**、能打开、Gatekeeper 不拦。
5. `plutil -p dist/UDIDRegisterMac.app/Contents/Info.plist | grep CFBundleIdentifier` — 应为 `com.pangu.UDIDRegisterMac`。
6. **Keychain 一致性关键验证**：在打包版里「导入配置文件…」导入一份 `.udidconfig` → 关闭 app → 重开 → 该账号凭据仍可用（额度能刷新出来）。证明打包版 bundle-id 与 Keychain service 一致。

---

## 自检（Self-Review）

- **Spec 覆盖**：①bundle-id→Task1/5；②图标+Info.plist→Task4/5；③一键配置导出导入→Task2/6/7；④中文报错→Task3/6/7；⑤使用说明→Task8；⑥删除确认→Task7。全覆盖。
- **类型一致性**：`AppIdentifiers.bundleID`、`AccountConfig`/`AccountConfigCodec.encode|decode|currentVersion`、`UserFacingMessage.from`、`AppModel.exportConfig(for:)`/`importConfig(from:)` 在定义与调用处名称/签名一致。
- **无占位符**：每个代码步骤均为可直接落地的完整代码。
- **权限依赖**：导出写文件依赖 Task 5 的读写 entitlement——已在计划内，Task 7 的导出功能排在 Task 5 之后。
```
