# ReSign 计划 2（构建顺序）：ReSignKit 重签引擎 —— Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增 `ReSignKit` 库：把私钥+证书导入临时钥匙串成为可用签名身份（codesign 无弹窗）、解析描述文件抽取 entitlements、由内向外用 `codesign` 重签 `.app` 及嵌套代码、并对整个 `.ipa` 做「解包→重签→重打包」，产出可安装的重签 IPA。

**Architecture:** `ReSignKit` 是一个**不沙盒**、允许 shell-out（`/usr/bin/ditto`、`/usr/bin/codesign`、`/usr/bin/security`）的库，与纯网络的 `UDIDRegisterKit` 分层隔离。纯逻辑（描述文件解析、签名顺序枚举、codesign 参数拼装）走 TDD 单测；碰钥匙串/codesign/ditto 的集成部分由**真实端到端集成测试**做验收——测试内用 openssl 现场造一张一次性自签名代码签名身份，重签一个合成的最小 `.app`/`.ipa`，断言 `codesign --verify --deep --strict` 通过。这个端到端测试是本计划最重要的验收闸，最早消除「codesign 无弹窗签名」这一风险。

**Tech Stack:** Swift 5.9 / macOS 14 / Foundation / Security；系统工具 `ditto`/`codesign`/`security`（及测试用 `openssl`），全部经 `Process` 调用。依赖 `UDIDRegisterKit`（复用 `SigningKeyPair` 生成密钥对，仅测试与便捷 API 用）。

## Global Constraints

- 平台 macOS 14+，Swift 5.9。
- `ReSignKit` 是**新库 target**；与 `UDIDRegisterKit` 分开正是因为它要 shell-out 到系统签名工具、创建临时钥匙串——**不要**把这些放进沙盒的 `UDIDRegisterKit`。
- 不引入任何第三方依赖；仅 Foundation + Security + 系统 CLI。
- 所有外部命令统一经本计划 Task 1 的 `Subprocess.run` 调用（便于测试与错误捕获）；不要各处散落 `Process`。
- 集成测试若所需系统工具缺失（如 `/usr/bin/openssl`、`/usr/bin/codesign`）应 `XCTSkip`，不得静默假装通过。
- 临时钥匙串、临时目录必须在用完后清理（`defer`/`deinit`），绝不写进用户登录钥匙串或留下垃圾。
- 私钥来自调用方（`SecKey`）——`ReSignKit` 不生成、不持久化私钥。
- codesign 由内向外：先签 `Frameworks/*.dylib`、`Frameworks/*.framework`、`PlugIns/*.appex`、`Watch/*.app` 及其嵌套，**主 app 最后**；主 app 带 `--entitlements`。
- entitlements **从描述文件里抽取**，绝不声明描述文件未授权的权限。

---

### Task 1: 新建 ReSignKit target + Subprocess 工具

**Files:**
- Modify: `Package.swift`
- Create: `Sources/ReSignKit/Subprocess.swift`
- Test: `Tests/ReSignKitTests/SubprocessTests.swift`

**Interfaces:**
- Consumes: 无。
- Produces:
  - Package 新增库 target `ReSignKit`（依赖 `UDIDRegisterKit`）与测试 target `ReSignKitTests`。
  - `enum SubprocessError: Error { case launch(String); case nonZero(status: Int32, stderr: String) }`
  - `struct Subprocess`：
    - `struct Result { let status: Int32; let stdout: String; let stderr: String }`
    - `static func run(_ launchPath: String, _ args: [String], input: Data? = nil) throws -> Result`
    - `static func runChecked(_ launchPath: String, _ args: [String], input: Data? = nil) throws -> Result`（非 0 退出即抛 `SubprocessError.nonZero`）

- [ ] **Step 1: 写失败测试**

```swift
// Tests/ReSignKitTests/SubprocessTests.swift
import XCTest
@testable import ReSignKit

final class SubprocessTests: XCTestCase {
    func testRunCapturesStdoutAndStatus() throws {
        let r = try Subprocess.run("/bin/echo", ["hello"])
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.stdout, "hello\n")
    }
    func testRunCheckedThrowsOnNonZero() throws {
        // /usr/bin/false 退出码 1
        XCTAssertThrowsError(try Subprocess.runChecked("/usr/bin/false", [])) { err in
            guard case SubprocessError.nonZero(let status, _) = err else { return XCTFail("wrong error") }
            XCTAssertEqual(status, 1)
        }
    }
    func testRunFeedsStdin() throws {
        // cat 回显 stdin
        let r = try Subprocess.run("/bin/cat", [], input: Data("abc".utf8))
        XCTAssertEqual(r.stdout, "abc")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter SubprocessTests`
Expected: 编译失败（`ReSignKit` 模块 / `Subprocess` 不存在）。

- [ ] **Step 3: Package.swift 增加 target**

在 `Package.swift` 的 `targets:` 数组里，`UDIDRegisterKitTests` 之后加入两行：

```swift
        .target(name: "ReSignKit", dependencies: ["UDIDRegisterKit"]),
        .testTarget(name: "ReSignKitTests", dependencies: ["ReSignKit"]),
```

（保持既有 `UDIDRegisterKit`、`UDIDRegisterKitTests`、`UDIDRegisterApp` 三个 target 不动。）

- [ ] **Step 4: 实现 Subprocess**

```swift
// Sources/ReSignKit/Subprocess.swift
import Foundation

public enum SubprocessError: Error, LocalizedError {
    case launch(String)
    case nonZero(status: Int32, stderr: String)
    public var errorDescription: String? {
        switch self {
        case .launch(let m): return "无法启动子进程：\(m)"
        case .nonZero(let s, let e): return "命令失败（退出码 \(s)）：\(e)"
        }
    }
}

public struct Subprocess {
    public struct Result {
        public let status: Int32
        public let stdout: String
        public let stderr: String
    }

    public static func run(_ launchPath: String, _ args: [String], input: Data? = nil) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        let inPipe = Pipe()
        if input != nil { p.standardInput = inPipe }
        do { try p.run() } catch { throw SubprocessError.launch(error.localizedDescription) }
        if let input { inPipe.fileHandleForWriting.write(input); inPipe.fileHandleForWriting.closeFile() }
        let oData = out.fileHandleForReading.readDataToEndOfFile()
        let eData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus,
                      stdout: String(decoding: oData, as: UTF8.self),
                      stderr: String(decoding: eData, as: UTF8.self))
    }

    @discardableResult
    public static func runChecked(_ launchPath: String, _ args: [String], input: Data? = nil) throws -> Result {
        let r = try run(launchPath, args, input: input)
        guard r.status == 0 else { throw SubprocessError.nonZero(status: r.status, stderr: r.stderr) }
        return r
    }
}
```

- [ ] **Step 5: 运行确认通过**

Run: `swift test --filter SubprocessTests`
Expected: PASS（3/3）。并 `swift build` 通过。

- [ ] **Step 6: 提交**

```bash
git add Package.swift Sources/ReSignKit/Subprocess.swift Tests/ReSignKitTests/SubprocessTests.swift
git commit -m "feat(resignkit): add target + Subprocess runner"
```

---

### Task 2: ProvisioningProfile —— 描述文件解析 + entitlements 抽取

**Files:**
- Create: `Sources/ReSignKit/ProvisioningProfile.swift`
- Test: `Tests/ReSignKitTests/ProvisioningProfileTests.swift`

**Interfaces:**
- Consumes: `Subprocess`（Task 1）。
- Produces:
  - `struct ProvisioningProfile`：
    - `let entitlements: [String: Any]`，`let name: String`，`let uuid: String`，`let teamIdentifier: String?`，`let deviceUDIDs: [String]`
    - `init?(plist: [String: Any])`（从已解码的 plist 字典构造；`Entitlements` 缺失则 `nil`）
    - `static func decodePlist(fromMobileprovision url: URL) throws -> [String: Any]`（`security cms -D -i <url>` 解出内嵌 plist，再 `PropertyListSerialization` 解析）
    - `static func load(fromMobileprovision url: URL) throws -> ProvisioningProfile`（组合上面两步；解析失败抛 `ReSignError.invalidProfile`）
  - `enum ReSignError: Error { case invalidProfile; case appNotFound; case noExecutable; case codesignFailed(String); case identityImport(String) }`（本 Task 先建该枚举，后续 Task 复用）

- [ ] **Step 1: 写失败测试**

```swift
// Tests/ReSignKitTests/ProvisioningProfileTests.swift
import XCTest
@testable import ReSignKit

final class ProvisioningProfileTests: XCTestCase {
    func testInitParsesEntitlementsAndFields() throws {
        let plist: [String: Any] = [
            "Name": "AdHoc-com.a.b",
            "UUID": "ABCD-1234",
            "TeamIdentifier": ["TEAMID9"],
            "ProvisionedDevices": ["udid1", "udid2"],
            "Entitlements": [
                "application-identifier": "TEAMID9.com.a.b",
                "get-task-allow": false
            ]
        ]
        let p = try XCTUnwrap(ProvisioningProfile(plist: plist))
        XCTAssertEqual(p.name, "AdHoc-com.a.b")
        XCTAssertEqual(p.uuid, "ABCD-1234")
        XCTAssertEqual(p.teamIdentifier, "TEAMID9")
        XCTAssertEqual(p.deviceUDIDs, ["udid1", "udid2"])
        XCTAssertEqual(p.entitlements["application-identifier"] as? String, "TEAMID9.com.a.b")
    }
    func testInitNilWhenNoEntitlements() {
        XCTAssertNil(ProvisioningProfile(plist: ["Name": "x", "UUID": "y"]))
    }
}
```

> 注：`decodePlist(fromMobileprovision:)`（shell-out `security cms -D`）的集成往返测试放在 Task 5——因为它需要 Task 5 才建立的一次性自签名身份来 `cms -S` 造一个测试用 `.mobileprovision`。本 Task 只做纯解析（`init?(plist:)`），两个用例本 Task 即全绿，无跨任务依赖。

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter ProvisioningProfileTests`
Expected: 编译失败（类型不存在）。

- [ ] **Step 3: 实现**

```swift
// Sources/ReSignKit/ProvisioningProfile.swift
import Foundation

public enum ReSignError: Error, LocalizedError {
    case invalidProfile
    case appNotFound
    case noExecutable
    case codesignFailed(String)
    case identityImport(String)
    public var errorDescription: String? {
        switch self {
        case .invalidProfile: return "描述文件无法解析（不是有效的 .mobileprovision）"
        case .appNotFound: return "IPA 内找不到 Payload/*.app"
        case .noExecutable: return "app bundle 缺少可执行文件"
        case .codesignFailed(let m): return "codesign 失败：\(m)"
        case .identityImport(let m): return "导入签名身份失败：\(m)"
        }
    }
}

public struct ProvisioningProfile {
    public let entitlements: [String: Any]
    public let name: String
    public let uuid: String
    public let teamIdentifier: String?
    public let deviceUDIDs: [String]

    public init?(plist: [String: Any]) {
        guard let ent = plist["Entitlements"] as? [String: Any] else { return nil }
        self.entitlements = ent
        self.name = (plist["Name"] as? String) ?? ""
        self.uuid = (plist["UUID"] as? String) ?? ""
        self.teamIdentifier = (plist["TeamIdentifier"] as? [String])?.first
        self.deviceUDIDs = (plist["ProvisionedDevices"] as? [String]) ?? []
    }

    /// `security cms -D` 解出 .mobileprovision 内嵌的 plist
    public static func decodePlist(fromMobileprovision url: URL) throws -> [String: Any] {
        let r = try Subprocess.runChecked("/usr/bin/security", ["cms", "-D", "-i", url.path])
        guard let data = r.stdout.data(using: .utf8),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else { throw ReSignError.invalidProfile }
        return dict
    }

    public static func load(fromMobileprovision url: URL) throws -> ProvisioningProfile {
        guard let p = ProvisioningProfile(plist: try decodePlist(fromMobileprovision: url)) else {
            throw ReSignError.invalidProfile
        }
        return p
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter ProvisioningProfileTests`
Expected: PASS（2/2 纯解析用例；CMS 往返集成测试在 Task 5 加入）。

- [ ] **Step 5: 提交**

```bash
git add Sources/ReSignKit/ProvisioningProfile.swift Tests/ReSignKitTests/ProvisioningProfileTests.swift
git commit -m "feat(resignkit): provisioning profile parse + entitlements extraction"
```

---

### Task 3: AppBundle —— 由内向外的签名顺序枚举

**Files:**
- Create: `Sources/ReSignKit/AppBundle.swift`
- Test: `Tests/ReSignKitTests/AppBundleTests.swift`

**Interfaces:**
- Consumes: 无。
- Produces:
  - `struct AppBundle`：
    - `let appDir: URL`
    - `init(appDir: URL)`
    - `func infoPlistURL() -> URL`（`appDir/Info.plist`）
    - `func bundleIdentifier() throws -> String`（读 Info.plist 的 `CFBundleIdentifier`）
    - `func embeddedProfileURL() -> URL`（`appDir/embedded.mobileprovision`）
    - `func codeToSignInsideOut() -> [URL]`（返回由内向外的签名目标顺序：嵌套 dylib/framework/appex/watch 在前，`appDir` 自身在最后一个）

- [ ] **Step 1: 写失败测试**

```swift
// Tests/ReSignKitTests/AppBundleTests.swift
import XCTest
@testable import ReSignKit

final class AppBundleTests: XCTestCase {
    func testInsideOutOrderingPutsMainAppLast() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("abt-\(UUID().uuidString)")
        let app = tmp.appendingPathComponent("Sample.app")
        let fw = app.appendingPathComponent("Frameworks/Lib.framework")
        let dylib = app.appendingPathComponent("Frameworks/libx.dylib")
        let appex = app.appendingPathComponent("PlugIns/Ext.appex")
        for d in [fw, appex] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(at: dylib.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dylib.path, contents: Data([0xCF, 0xFA]))
        FileManager.default.createFile(atPath: app.appendingPathComponent("Info.plist").path, contents: Data())
        defer { try? FileManager.default.removeItem(at: tmp) }

        let targets = AppBundle(appDir: app).codeToSignInsideOut()
        XCTAssertEqual(targets.last, app, "主 app 必须最后签")
        // 三个嵌套项都在主 app 之前
        XCTAssertTrue(targets.contains(fw)); XCTAssertTrue(targets.contains(dylib)); XCTAssertTrue(targets.contains(appex))
        XCTAssertLessThan(targets.firstIndex(of: fw)!, targets.firstIndex(of: app)!)
        XCTAssertLessThan(targets.firstIndex(of: appex)!, targets.firstIndex(of: app)!)
    }
    func testBundleIdentifierReadsInfoPlist() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("abt2-\(UUID().uuidString)")
        let app = tmp.appendingPathComponent("S.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "com.a.b"] as NSDictionary).write(to: app.appendingPathComponent("Info.plist"))
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertEqual(try AppBundle(appDir: app).bundleIdentifier(), "com.a.b")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter AppBundleTests`
Expected: 编译失败（`AppBundle` 不存在）。

- [ ] **Step 3: 实现**

```swift
// Sources/ReSignKit/AppBundle.swift
import Foundation

public struct AppBundle {
    public let appDir: URL
    public init(appDir: URL) { self.appDir = appDir }

    public func infoPlistURL() -> URL { appDir.appendingPathComponent("Info.plist") }
    public func embeddedProfileURL() -> URL { appDir.appendingPathComponent("embedded.mobileprovision") }

    public func bundleIdentifier() throws -> String {
        let data = try Data(contentsOf: infoPlistURL())
        let obj = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = obj as? [String: Any], let id = dict["CFBundleIdentifier"] as? String else {
            throw ReSignError.invalidProfile
        }
        return id
    }

    /// 由内向外收集需签名的代码：嵌套 framework/dylib/appex/watch app 在前，主 app 最后。
    public func codeToSignInsideOut() -> [URL] {
        let fm = FileManager.default
        var nested: [URL] = []
        func collect(in dir: URL, exts: Set<String>) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
            for u in items where exts.contains(u.pathExtension) { nested.append(u) }
        }
        collect(in: appDir.appendingPathComponent("Frameworks"), exts: ["framework", "dylib"])
        collect(in: appDir.appendingPathComponent("PlugIns"), exts: ["appex"])
        // Watch app（若有）：Watch/*.app 及其内层 PlugIns
        let watch = appDir.appendingPathComponent("Watch")
        if let watchApps = try? fm.contentsOfDirectory(at: watch, includingPropertiesForKeys: nil) {
            for w in watchApps where w.pathExtension == "app" {
                collect(in: w.appendingPathComponent("Frameworks"), exts: ["framework", "dylib"])
                collect(in: w.appendingPathComponent("PlugIns"), exts: ["appex"])
                nested.append(w)
            }
        }
        return nested + [appDir]   // 主 app 最后
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter AppBundleTests`
Expected: PASS（2/2）。

- [ ] **Step 5: 提交**

```bash
git add Sources/ReSignKit/AppBundle.swift Tests/ReSignKitTests/AppBundleTests.swift
git commit -m "feat(resignkit): inside-out code-signing target enumeration"
```

---

### Task 4: CodesignInvocation —— codesign 参数拼装（纯函数）

**Files:**
- Create: `Sources/ReSignKit/CodesignInvocation.swift`
- Test: `Tests/ReSignKitTests/CodesignInvocationTests.swift`

**Interfaces:**
- Consumes: 无。
- Produces:
  - `enum CodesignInvocation`：
    - `static func signArgs(identity: String, target: String, entitlements: String?) -> [String]`
      （`["--force", "--sign", identity, ...(entitlements 有则 "--entitlements", path), "--timestamp=none", target]`）
    - `static func verifyArgs(target: String) -> [String]`
      （`["--verify", "--deep", "--strict", "--verbose=2", target]`）

- [ ] **Step 1: 写失败测试**

```swift
// Tests/ReSignKitTests/CodesignInvocationTests.swift
import XCTest
@testable import ReSignKit

final class CodesignInvocationTests: XCTestCase {
    func testSignArgsWithEntitlements() {
        let a = CodesignInvocation.signArgs(identity: "ABC123", target: "/x/A.app", entitlements: "/tmp/e.plist")
        XCTAssertEqual(a.first, "--force")
        XCTAssertEqual(a[1], "--sign"); XCTAssertEqual(a[2], "ABC123")
        XCTAssertTrue(a.contains("--entitlements")); XCTAssertTrue(a.contains("/tmp/e.plist"))
        XCTAssertEqual(a.last, "/x/A.app")
    }
    func testSignArgsWithoutEntitlementsOmitsFlag() {
        let a = CodesignInvocation.signArgs(identity: "ABC123", target: "/x/lib.dylib", entitlements: nil)
        XCTAssertFalse(a.contains("--entitlements"))
        XCTAssertEqual(a.last, "/x/lib.dylib")
    }
    func testVerifyArgs() {
        XCTAssertEqual(CodesignInvocation.verifyArgs(target: "/x/A.app"),
                       ["--verify", "--deep", "--strict", "--verbose=2", "/x/A.app"])
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter CodesignInvocationTests`
Expected: 编译失败。

- [ ] **Step 3: 实现**

```swift
// Sources/ReSignKit/CodesignInvocation.swift
import Foundation

public enum CodesignInvocation {
    public static func signArgs(identity: String, target: String, entitlements: String?) -> [String] {
        var a = ["--force", "--sign", identity]
        if let entitlements { a += ["--entitlements", entitlements] }
        a += ["--timestamp=none", target]   // ad hoc 分发不需要时间戳服务
        return a
    }
    public static func verifyArgs(target: String) -> [String] {
        ["--verify", "--deep", "--strict", "--verbose=2", target]
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter CodesignInvocationTests`
Expected: PASS（3/3）。

- [ ] **Step 5: 提交**

```bash
git add Sources/ReSignKit/CodesignInvocation.swift Tests/ReSignKitTests/CodesignInvocationTests.swift
git commit -m "feat(resignkit): codesign argument builders"
```

---

### Task 5: TemporaryKeychainIdentity + 测试支撑（风险核心：无弹窗签名）

**Files:**
- Create: `Sources/ReSignKit/TemporaryKeychainIdentity.swift`
- Create: `Tests/ReSignKitTests/TestSupport.swift`（`TestTemp` + `TestSigningFixture`）
- Test: `Tests/ReSignKitTests/TemporaryKeychainIdentityTests.swift`
- Modify: `Tests/ReSignKitTests/ProvisioningProfileTests.swift`（回填 Task 2 里依赖 fixture 的集成用例——去掉其 skip）

**Interfaces:**
- Consumes: `Subprocess`（Task 1）、`ReSignError`（Task 2）。
- Produces:
  - `final class TemporaryKeychainIdentity`：
    - `init(privateKey: SecKey, certificateDER: Data, commonName: String) throws`
      （建临时钥匙串 → 导入 key+cert → `set-key-partition-list` 放行 `apple:`/codesign → 记录 keychain 路径与 identity 名）
    - `let keychainPath: String`，`let signingIdentity: String`（供 codesign `--sign` 用，用 commonName 或 SHA-1）
    - `func addToSearchListForCodesign() throws`（把临时钥匙串并入搜索域，让 codesign 找得到）
    - `func cleanup()`（删除临时钥匙串文件并从搜索域移除；`deinit` 兜底调用）
  - 测试支撑：
    - `enum TestTemp { static func dir() throws -> URL }`
    - `struct TestSigningFixture`：`let keychainPath: String`、`let commonName: String`、`let privateKey: SecKey`、`let certificateDER: Data`、`func cleanup()`；`static func make(in dir: URL) throws -> TestSigningFixture`——用 `SigningKeyPair.generateRSA2048()` 造 key，导出私钥 PEM，`openssl req -x509` 自签一张代码签名证书（DER），构造 `TemporaryKeychainIdentity` 并返回其内部字段，供各集成测试复用。

> **实现风险提示（本计划最不确定处）**：把「进程内生成的 `SecKey` + 证书」变成 codesign 可无弹窗使用的钥匙串身份，涉及 `SecItemAdd`(kSecUseKeychain) 或 `security import`、`security set-key-partition-list -S apple-tool:,apple:,codesign: -k "" <keychain>`、以及把临时钥匙串加入 `security list-keychains`。这里的确切命令/顺序**以集成测试通过为准**——实现者应以「Task 6 端到端 `codesign --verify` 通过且签名过程无交互弹窗」作为验收，允许对下面给出的具体命令做经验性调整，并在报告中记录最终可行的命令序列。给出的实现是**经过论证的起点**，不是保证逐字正确的终稿。

- [ ] **Step 1: 写失败测试**

```swift
// Tests/ReSignKitTests/TemporaryKeychainIdentityTests.swift
import XCTest
import Security
@testable import ReSignKit

final class TemporaryKeychainIdentityTests: XCTestCase {
    func testImportedIdentityCanCodesignAFileWithoutPrompt() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/codesign"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/security") else { throw XCTSkip("no tools") }
        let tmp = try TestTemp.dir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let fx = try TestSigningFixture.make(in: tmp); defer { fx.cleanup() }

        // 用一个真实 mach-o（拷贝 /bin/echo）作为待签目标
        let target = tmp.appendingPathComponent("echo-copy")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: target)

        let id = try TemporaryKeychainIdentity(privateKey: fx.privateKey,
                                               certificateDER: fx.certificateDER, commonName: fx.commonName)
        defer { id.cleanup() }
        try id.addToSearchListForCodesign()
        // 无弹窗签名：codesign 退出 0
        let r = try Subprocess.run("/usr/bin/codesign",
            CodesignInvocation.signArgs(identity: id.signingIdentity, target: target.path, entitlements: nil)
            + ["--keychain", id.keychainPath])
        XCTAssertEqual(r.status, 0, "签名应无弹窗且成功：\(r.stderr)")
        let v = try Subprocess.run("/usr/bin/codesign", ["--verify", "--verbose=2", target.path])
        XCTAssertEqual(v.status, 0, "验签应通过：\(v.stderr)")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter TemporaryKeychainIdentityTests`
Expected: 编译失败（`TemporaryKeychainIdentity`/`TestSigningFixture` 不存在）。

- [ ] **Step 3: 实现测试支撑 TestSupport.swift**

```swift
// Tests/ReSignKitTests/TestSupport.swift
import Foundation
import Security
import UDIDRegisterKit
@testable import ReSignKit

enum TestTemp {
    static func dir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("resignkit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

/// 一次性自签名「代码签名」身份：进程内生成 RSA key，openssl 自签一张证书（DER），
/// 供 TemporaryKeychainIdentity / security cms 等集成测试复用。
struct TestSigningFixture {
    let keychainPath: String
    let commonName: String
    let privateKey: SecKey
    let certificateDER: Data
    private let cleanupPaths: [String]

    func cleanup() {
        _ = try? Subprocess.run("/usr/bin/security", ["delete-keychain", keychainPath])
        for p in cleanupPaths { try? FileManager.default.removeItem(atPath: p) }
    }

    static func make(in dir: URL) throws -> TestSigningFixture {
        let cn = "ReSignKit Test \(UUID().uuidString.prefix(8))"
        let kp = try SigningKeyPair.generateRSA2048()
        // 导出私钥为 PKCS#1 PEM 供 openssl 使用
        var err: Unmanaged<CFError>?
        guard let privDER = SecKeyCopyExternalRepresentation(kp.privateKey, &err) as Data? else {
            throw ReSignError.identityImport("导出私钥失败")
        }
        let keyPEM = dir.appendingPathComponent("key.pem")
        try pkcs1PEM(privDER).write(to: keyPEM, atomically: true, encoding: .utf8)
        // openssl 自签一张代码签名证书（DER）
        let certDERURL = dir.appendingPathComponent("cert.der")
        try Subprocess.runChecked("/usr/bin/openssl", ["req", "-x509", "-new", "-key", keyPEM.path,
            "-subj", "/CN=\(cn)", "-days", "1", "-outform", "DER", "-out", certDERURL.path])
        let certDER = try Data(contentsOf: certDERURL)
        // 临时钥匙串（TemporaryKeychainIdentity 内部也会建；这里给 fixture 自己一份供 cms 测试）
        let keychain = dir.appendingPathComponent("t.keychain").path
        _ = try? Subprocess.run("/usr/bin/security", ["delete-keychain", keychain])
        try Subprocess.runChecked("/usr/bin/security", ["create-keychain", "-p", "", keychain])
        try Subprocess.runChecked("/usr/bin/security", ["unlock-keychain", "-p", "", keychain])
        // 造 p12 导入（openssl 组装 key+cert → p12 → security import）
        let certPEM = dir.appendingPathComponent("cert.pem")
        try Subprocess.runChecked("/usr/bin/openssl", ["x509", "-inform", "DER", "-in", certDERURL.path, "-out", certPEM.path])
        let p12 = dir.appendingPathComponent("id.p12")
        try Subprocess.runChecked("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", keyPEM.path,
            "-in", certPEM.path, "-out", p12.path, "-passout", "pass:", "-name", cn])
        try Subprocess.runChecked("/usr/bin/security", ["import", p12.path, "-k", keychain,
            "-P", "", "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"])
        try Subprocess.runChecked("/usr/bin/security",
            ["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-k", "", keychain])
        return TestSigningFixture(keychainPath: keychain, commonName: cn,
                                  privateKey: kp.privateKey, certificateDER: certDER,
                                  cleanupPaths: [keyPEM.path, certDERURL.path, certPEM.path, p12.path])
    }

    /// 把 PKCS#1 RSAPrivateKey DER 包成 PEM
    static func pkcs1PEM(_ der: Data) -> String {
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN RSA PRIVATE KEY-----\n\(b64)\n-----END RSA PRIVATE KEY-----\n"
    }
}
```

- [ ] **Step 4: 实现 TemporaryKeychainIdentity.swift**

```swift
// Sources/ReSignKit/TemporaryKeychainIdentity.swift
import Foundation
import Security

/// 把私钥+证书导入一个临时钥匙串，成为 codesign 可无弹窗使用的签名身份；用完清理。
public final class TemporaryKeychainIdentity {
    public let keychainPath: String
    public let signingIdentity: String   // 传给 codesign --sign（用 commonName）
    private let password = ""
    private var cleaned = false

    public init(privateKey: SecKey, certificateDER: Data, commonName: String) throws {
        self.signingIdentity = commonName
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("resign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.keychainPath = dir.appendingPathComponent("signing.keychain").path

        _ = try? Subprocess.run("/usr/bin/security", ["delete-keychain", keychainPath])
        try Subprocess.runChecked("/usr/bin/security", ["create-keychain", "-p", password, keychainPath])
        try Subprocess.runChecked("/usr/bin/security", ["unlock-keychain", "-p", password, keychainPath])

        // 组装 p12（openssl）再 import——比 SecItemAdd 跨版本更稳
        var err: Unmanaged<CFError>?
        guard let privDER = SecKeyCopyExternalRepresentation(privateKey, &err) as Data? else {
            throw ReSignError.identityImport("导出私钥失败")
        }
        let keyPEM = dir.appendingPathComponent("k.pem")
        try TemporaryKeychainIdentity.pkcs1PEM(privDER).write(to: keyPEM, atomically: true, encoding: .utf8)
        let certDERURL = dir.appendingPathComponent("c.der"); try certificateDER.write(to: certDERURL)
        let certPEM = dir.appendingPathComponent("c.pem")
        try Subprocess.runChecked("/usr/bin/openssl", ["x509", "-inform", "DER", "-in", certDERURL.path, "-out", certPEM.path])
        let p12 = dir.appendingPathComponent("id.p12")
        try Subprocess.runChecked("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", keyPEM.path,
            "-in", certPEM.path, "-out", p12.path, "-passout", "pass:", "-name", commonName])
        try Subprocess.runChecked("/usr/bin/security", ["import", p12.path, "-k", keychainPath,
            "-P", "", "-T", "/usr/bin/codesign"])
        // 放行 codesign 无交互使用私钥
        try Subprocess.runChecked("/usr/bin/security",
            ["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-k", password, keychainPath])
        // 清理明文中间产物（p12/pem），保留钥匙串
        for u in [keyPEM, certPEM, certDERURL, p12] { try? FileManager.default.removeItem(at: u) }
    }

    /// 把临时钥匙串并入搜索域，让 codesign 找得到身份
    public func addToSearchListForCodesign() throws {
        let list = try Subprocess.run("/usr/bin/security", ["list-keychains", "-d", "user"])
        let existing = list.stdout.split(separator: "\n").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        }
        try Subprocess.runChecked("/usr/bin/security",
            ["list-keychains", "-d", "user", "-s"] + existing + [keychainPath])
    }

    public func cleanup() {
        guard !cleaned else { return }
        cleaned = true
        _ = try? Subprocess.run("/usr/bin/security", ["delete-keychain", keychainPath])
    }
    deinit { cleanup() }

    static func pkcs1PEM(_ der: Data) -> String {
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN RSA PRIVATE KEY-----\n\(b64)\n-----END RSA PRIVATE KEY-----\n"
    }
}
```

- [ ] **Step 5: 运行确认通过 + 用 fixture 补 Task 2 的 CMS 往返集成测试**

Run: `swift test --filter TemporaryKeychainIdentityTests`
Expected: PASS（若 `codesign`/`openssl`/`security` 齐全）——**签名无弹窗、验签通过**。若命令序列需微调，以此测试通过为准并记录。

然后把下面这个集成测试**追加**到 `Tests/ReSignKitTests/ProvisioningProfileTests.swift` 的 `ProvisioningProfileTests` 类里（现在 fixture 已就绪，验证 `security cms -D` 往返）：

```swift
    func testDecodePlistRoundTripsViaSecurityCMS() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/security"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") else { throw XCTSkip("no tools") }
        let tmp = try TestTemp.dir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let plist = tmp.appendingPathComponent("in.plist")
        try (["Entitlements": ["application-identifier": "T.com.a.b"], "Name": "n", "UUID": "u"] as NSDictionary)
            .write(to: plist)
        let fx = try TestSigningFixture.make(in: tmp); defer { fx.cleanup() }
        let signed = tmp.appendingPathComponent("p.mobileprovision")
        try Subprocess.runChecked("/usr/bin/security",
            ["cms", "-S", "-N", fx.commonName, "-k", fx.keychainPath, "-i", plist.path, "-o", signed.path])
        let decoded = try ProvisioningProfile.decodePlist(fromMobileprovision: signed)
        XCTAssertEqual(decoded["Name"] as? String, "n")
        let profile = try ProvisioningProfile.load(fromMobileprovision: signed)
        XCTAssertEqual(profile.entitlements["application-identifier"] as? String, "T.com.a.b")
    }
```

Run: `swift test --filter ProvisioningProfileTests` → 全 PASS（含新集成用例）。

- [ ] **Step 6: 提交**

```bash
git add Sources/ReSignKit/TemporaryKeychainIdentity.swift Tests/ReSignKitTests/TestSupport.swift Tests/ReSignKitTests/TemporaryKeychainIdentityTests.swift Tests/ReSignKitTests/ProvisioningProfileTests.swift
git commit -m "feat(resignkit): temporary-keychain signing identity (no-prompt codesign)"
```

---

### Task 6: AppResigner —— 重签一个 .app（端到端集成验收）

**Files:**
- Create: `Sources/ReSignKit/AppResigner.swift`
- Test: `Tests/ReSignKitTests/AppResignerTests.swift`

**Interfaces:**
- Consumes: `AppBundle`（Task 3）、`CodesignInvocation`（Task 4）、`TemporaryKeychainIdentity`（Task 5）、`ProvisioningProfile`（Task 2）、`Subprocess`（Task 1）、`TestSigningFixture`（Task 5，测试用）。
- Produces:
  - `struct AppResigner`：
    - `static func resign(appDir: URL, identity: TemporaryKeychainIdentity, profileData: Data, entitlements: [String: Any]) throws`
      （① 写 `embedded.mobileprovision` = profileData；② entitlements 写临时 plist；③ 对 `AppBundle.codeToSignInsideOut()` 逐个 codesign——主 app 带 entitlements，嵌套项不带；④ `codesign --verify --deep --strict` 主 app；失败抛 `ReSignError.codesignFailed`）

- [ ] **Step 1: 写失败测试（端到端）**

```swift
// Tests/ReSignKitTests/AppResignerTests.swift
import XCTest
@testable import ReSignKit

final class AppResignerTests: XCTestCase {
    func testResignSyntheticAppVerifiesAndCarriesEntitlements() throws {
        for tool in ["/usr/bin/codesign", "/usr/bin/openssl", "/usr/bin/security"] {
            guard FileManager.default.isExecutableFile(atPath: tool) else { throw XCTSkip("no \(tool)") }
        }
        let tmp = try TestTemp.dir(); defer { try? FileManager.default.removeItem(at: tmp) }
        // 合成最小 .app：Info.plist + 真实 mach-o 作为可执行文件
        let app = tmp.appendingPathComponent("Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "com.demo.app", "CFBundleExecutable": "Demo"] as NSDictionary)
            .write(to: app.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"),
                                         to: app.appendingPathComponent("Demo"))

        let fx = try TestSigningFixture.make(in: tmp); defer { fx.cleanup() }
        let id = try TemporaryKeychainIdentity(privateKey: fx.privateKey,
                                               certificateDER: fx.certificateDER, commonName: fx.commonName)
        defer { id.cleanup() }
        try id.addToSearchListForCodesign()

        let ent: [String: Any] = ["application-identifier": "TEAMID.com.demo.app", "get-task-allow": false]
        try AppResigner.resign(appDir: app, identity: id,
                               profileData: Data("FAKE-PROFILE".utf8), entitlements: ent)

        // 描述文件已写入
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("embedded.mobileprovision").path))
        // 验签通过
        let v = try Subprocess.run("/usr/bin/codesign", CodesignInvocation.verifyArgs(target: app.path) + ["--keychain", id.keychainPath])
        XCTAssertEqual(v.status, 0, "验签应通过：\(v.stderr)")
        // entitlements 落到了签名里
        let d = try Subprocess.run("/usr/bin/codesign", ["-d", "--entitlements", ":-", app.path])
        XCTAssertTrue(d.stdout.contains("com.demo.app"), "应能读回 entitlements")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter AppResignerTests`
Expected: 编译失败（`AppResigner` 不存在）。

- [ ] **Step 3: 实现**

```swift
// Sources/ReSignKit/AppResigner.swift
import Foundation

public struct AppResigner {
    public static func resign(appDir: URL, identity: TemporaryKeychainIdentity,
                              profileData: Data, entitlements: [String: Any]) throws {
        let bundle = AppBundle(appDir: appDir)
        // ① 写描述文件
        try profileData.write(to: bundle.embeddedProfileURL())
        // ② entitlements 落临时 plist
        let entURL = appDir.deletingLastPathComponent().appendingPathComponent("entitlements-\(UUID().uuidString).plist")
        let entData = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
        try entData.write(to: entURL)
        defer { try? FileManager.default.removeItem(at: entURL) }

        // ③ 由内向外签名
        let targets = bundle.codeToSignInsideOut()
        for t in targets {
            let isMainApp = (t == appDir)
            let args = CodesignInvocation.signArgs(identity: identity.signingIdentity,
                        target: t.path, entitlements: isMainApp ? entURL.path : nil)
                        + ["--keychain", identity.keychainPath]
            let r = try Subprocess.run("/usr/bin/codesign", args)
            guard r.status == 0 else { throw ReSignError.codesignFailed("\(t.lastPathComponent): \(r.stderr)") }
        }
        // ④ 验签
        let v = try Subprocess.run("/usr/bin/codesign",
            CodesignInvocation.verifyArgs(target: appDir.path) + ["--keychain", identity.keychainPath])
        guard v.status == 0 else { throw ReSignError.codesignFailed("verify: \(v.stderr)") }
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter AppResignerTests`
Expected: PASS——**这是本计划的关键验收：真实 codesign 重签 + 验签通过 + entitlements 读得回**。若通不过，按 Task 5 的风险提示调整钥匙串/codesign 命令直至通过，并在报告记录最终命令。

- [ ] **Step 5: 提交**

```bash
git add Sources/ReSignKit/AppResigner.swift Tests/ReSignKitTests/AppResignerTests.swift
git commit -m "feat(resignkit): resign .app inside-out with entitlements + verify (e2e)"
```

---

### Task 7: IPAResigner —— 解包→重签→重打包整个 IPA

**Files:**
- Create: `Sources/ReSignKit/IPAResigner.swift`
- Test: `Tests/ReSignKitTests/IPAResignerTests.swift`

**Interfaces:**
- Consumes: `AppResigner`（Task 6）、`Subprocess`（Task 1）、`ReSignError`（Task 2）。
- Produces:
  - `struct IPAResigner`：
    - `static func resign(ipaURL: URL, outputURL: URL, identity: TemporaryKeychainIdentity, profileData: Data, entitlements: [String: Any]) throws`
      （`ditto -x -k` 解包到临时目录 → 找 `Payload/*.app`（无则抛 `appNotFound`）→ `AppResigner.resign` → `ditto -c -k --sequesterRsrc --keepParent Payload outputURL`；临时目录用完清理）
    - `static func findPayloadApp(in unpackedDir: URL) -> URL?`（`unpackedDir/Payload/*.app` 第一个）

- [ ] **Step 1: 写失败测试（round-trip）**

```swift
// Tests/ReSignKitTests/IPAResignerTests.swift
import XCTest
@testable import ReSignKit

final class IPAResignerTests: XCTestCase {
    func testResignIPARoundTripsAndVerifies() throws {
        for tool in ["/usr/bin/ditto", "/usr/bin/codesign", "/usr/bin/openssl", "/usr/bin/security"] {
            guard FileManager.default.isExecutableFile(atPath: tool) else { throw XCTSkip("no \(tool)") }
        }
        let tmp = try TestTemp.dir(); defer { try? FileManager.default.removeItem(at: tmp) }
        // 合成 Payload/Demo.app 并 ditto 打成 .ipa
        let payload = tmp.appendingPathComponent("Payload")
        let app = payload.appendingPathComponent("Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "com.demo.app", "CFBundleExecutable": "Demo"] as NSDictionary)
            .write(to: app.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: app.appendingPathComponent("Demo"))
        let ipa = tmp.appendingPathComponent("in.ipa")
        try Subprocess.runChecked("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", payload.path, ipa.path])

        let fx = try TestSigningFixture.make(in: tmp); defer { fx.cleanup() }
        let id = try TemporaryKeychainIdentity(privateKey: fx.privateKey,
                                               certificateDER: fx.certificateDER, commonName: fx.commonName)
        defer { id.cleanup() }
        try id.addToSearchListForCodesign()

        let out = tmp.appendingPathComponent("out.ipa")
        try IPAResigner.resign(ipaURL: ipa, outputURL: out, identity: id,
                               profileData: Data("FAKE".utf8),
                               entitlements: ["application-identifier": "T.com.demo.app"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        // 解开输出，验签
        let check = tmp.appendingPathComponent("check")
        try Subprocess.runChecked("/usr/bin/ditto", ["-x", "-k", out.path, check.path])
        let outApp = check.appendingPathComponent("Payload/Demo.app")
        let v = try Subprocess.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", outApp.path, "--keychain", id.keychainPath])
        XCTAssertEqual(v.status, 0, "重签后的 IPA 应验签通过：\(v.stderr)")
    }

    func testFindPayloadAppNilWhenMissing() throws {
        let tmp = try TestTemp.dir(); defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertNil(IPAResigner.findPayloadApp(in: tmp))
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter IPAResignerTests`
Expected: 编译失败（`IPAResigner` 不存在）。

- [ ] **Step 3: 实现**

```swift
// Sources/ReSignKit/IPAResigner.swift
import Foundation

public struct IPAResigner {
    public static func findPayloadApp(in unpackedDir: URL) -> URL? {
        let payload = unpackedDir.appendingPathComponent("Payload")
        let items = (try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)) ?? []
        return items.first { $0.pathExtension == "app" }
    }

    public static func resign(ipaURL: URL, outputURL: URL, identity: TemporaryKeychainIdentity,
                              profileData: Data, entitlements: [String: Any]) throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ipa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // 解包
        try Subprocess.runChecked("/usr/bin/ditto", ["-x", "-k", ipaURL.path, work.path])
        guard let app = findPayloadApp(in: work) else { throw ReSignError.appNotFound }

        // 重签
        try AppResigner.resign(appDir: app, identity: identity, profileData: profileData, entitlements: entitlements)

        // 重打包（覆盖已存在的输出）
        try? FileManager.default.removeItem(at: outputURL)
        try Subprocess.runChecked("/usr/bin/ditto",
            ["-c", "-k", "--sequesterRsrc", "--keepParent",
             work.appendingPathComponent("Payload").path, outputURL.path])
    }
}
```

- [ ] **Step 4: 运行确认通过（全量）**

Run: `swift test`（跑全量，确认 UDIDRegisterKit 59 个 + ReSignKit 新增全部通过，无回归）
Expected: 全绿。

- [ ] **Step 5: 提交**

```bash
git add Sources/ReSignKit/IPAResigner.swift Tests/ReSignKitTests/IPAResignerTests.swift
git commit -m "feat(resignkit): full IPA unpack→resign→repack round-trip (e2e)"
```

---

## Self-Review

**Spec coverage（对应 design「三个核心流程/3 重签引擎（ReSignKit）」）：**
- 临时钥匙串导入身份 + 无弹窗签名（partition-list）→ Task 5 ✅（本计划最大风险，端到端测试验收）
- 描述文件解析 + entitlements 抽取（从 profile 抽，不越权）→ Task 2 ✅
- 由内向外签名顺序（framework/dylib/appex/watch，主 app 最后）→ Task 3 + Task 6 ✅
- codesign 参数、执行、验签 → Task 4 + Task 6 ✅
- IPA 解包/换描述文件/重打包 → Task 7 ✅
- **不在本计划**：证书创建（Plan 1 已完成）、账号共享（延后到 ReSignApp bring-up）、UI（后续 ReSignApp 计划）、p12 导出（ReSignApp 便捷功能）、含独立 bundleId 的 appex 各自建 profile（v1 主流程先覆盖单 profile；多 profile 在 ReSignApp 计划按需补）。

**Placeholder scan：** 无 TBD/TODO；每个代码步骤含完整代码。Task 5/6 的钥匙串/codesign 命令明确标注「以集成测试通过为准、允许经验性微调」——这是系统集成的诚实处理，验收由真实 `codesign --verify` 定义，不是占位符。

**Type consistency：** `Subprocess`（Task 1）被 2/5/6/7 复用；`ReSignError`（Task 2）被 3/6/7 复用；`TemporaryKeychainIdentity`（Task 5）被 Task 6 `resign(appDir:identity:profileData:entitlements:)`、Task 7 `resign(ipaURL:outputURL:identity:profileData:entitlements:)` 一致引用；`TestSigningFixture`/`TestTemp`（Task 5 建立）被 Task 5/6/7 的集成测试复用。

**依赖顺序说明：** 每个 Task 完成时其测试即全绿——Task 2 只做纯解析（无跨任务依赖），`security cms -D` 的往返集成测试延后到 Task 5（fixture 就绪时）作为对 Task 2 代码的补充验证。这样安排是有意的：把风险最高的钥匙串/codesign 能力（Task 5/6）尽早用真实端到端测试锁死。**Task 6 的 `AppResigner` 端到端测试（真实 codesign 重签 + 验签通过 + entitlements 读回）是本计划的核心验收闸。**
