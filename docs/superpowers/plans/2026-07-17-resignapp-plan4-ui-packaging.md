# ReSignApp 计划 4：UI + 打包 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把已完成的 `ReSignModel` 核心逻辑接上 SwiftUI 界面并打包成独立的「重签助手」app，同时补齐 `exportP12` 与修复生产证书泄漏，做到「可交付前」全部就绪。

**Architecture:** 复用两个库层与 `ReSignAppCore`。新增：`ReSignModel` 的输出路径解析与 `exportP12`、`ReSignModel.live()` 生产接线（ReSignApp 专属账号库 + 钥匙串 service，与注册 app 隔离）、`TemporaryKeychainIdentity` 泄漏必修、`Sources/ReSignApp/` 的 `@main` + 视图、区分图标与 `scripts/package-resign.sh`。

**Tech Stack:** Swift 5.9 / SwiftUI / AppKit / SwiftPM（macOS 14）；`openssl` + `security` + `codesign` + `ditto`（子进程）；`notarytool` + `stapler`（打包，用户端跑）。

## Global Constraints

- 平台：`macOS(.v14)`，工具链 `swift-tools-version: 5.9`。
- **无弹窗 codesign**：签名靠叶证书 SHA-1 指纹 + `set-key-partition-list`，**绝不** `security add-trusted-cert`。
- **绝不污染 / 误删用户钥匙串**：泄漏修复只删「我们导入时新增那份」，import 前先快照；命令失败时保守不删。
- **p12 密码走 stdin**，绝不进 argv（避免 `ps` 泄露）；明文中间产物用完 shred + 删目录。
- **ReSignApp 数据与注册 app 完全隔离**：独立账号文件 `~/Library/Application Support/ReSignMac/accounts.json`，钥匙串 service = `ReSignAppIdentifiers.bundleID`（`com.pangu.ReSignMac`）与 `...".signing"`。
- **打包不沙盒**：`codesign --options runtime` + 空/最小 entitlements（不含 `app-sandbox`）。
- 所有回复与新增用户可见文案用中文。保持 `swift test` 全绿（当前 90/90）。
- 本会话做到「可交付前」：实现 + 本地 `swift build`/`swift test`/`swift run` 冒烟；**公证与真机 E2E 交用户执行**。

## 文件结构（先定边界）

- 改 `Sources/ReSignAppCore/ReSignModel.swift`：加 `resolveOutputURL(for:...)`（静态、可注入）、`exportP12(to:password:)`，`resign()` 改用解析器。
- 加 `Sources/ReSignAppCore/ReSignModelLive.swift`：`ReSignModel.live()` 工厂 + `liveAccountsFileURL()`。
- 改 `Sources/ReSignAppCore/SigningIdentityManager.swift`：加 `exportP12(for:password:)`。
- 改 `Sources/ReSignKit/TemporaryKeychainIdentity.swift`：import 前快照 + cleanup 条件删除。
- 删 `Sources/ReSignApp/main.swift`；加 `Sources/ReSignApp/ReSignApp.swift`（`@main` + AppDelegate）、`Sources/ReSignApp/ReSignRootView.swift`、`Sources/ReSignApp/PasswordSheet.swift`、`Sources/ReSignApp/AccountsSheet.swift`。
- 改 `scripts/make-icon.swift`：参数化出第二版区分图标 → `Resources/ReSignAppIcon.icns`。
- 加 `Resources/ReSignApp-Info.plist`、`Resources/ReSignApp.entitlements`、`scripts/package-resign.sh`。
- 测试：`Tests/ReSignAppCoreTests/ReSignModelTests.swift`（+输出路径、+live 冒烟）、`Tests/ReSignAppCoreTests/SigningIdentityManagerTests.swift`（+exportP12 往返）、`Tests/ReSignKitTests/TemporaryKeychainIdentityLeakTests.swift`（新增泄漏修复集成测试）。

---

### Task 1: 输出路径解析（同目录不可写 → 退回下载文件夹）

**Files:**
- Modify: `Sources/ReSignAppCore/ReSignModel.swift`
- Test: `Tests/ReSignAppCoreTests/ReSignModelTests.swift`

**Interfaces:**
- Produces: `static func resolveOutputURL(for source: URL, isDirWritable: (String) -> Bool, downloadsDir: () -> URL) -> URL`（两个闭包有默认值，便于注入）。`resign()` 内部改用它。

- [ ] **Step 1: 写失败测试**（加到 `ReSignModelTests`）

```swift
func testResolveOutputURLUsesSourceDirWhenWritable() {
    let src = URL(fileURLWithPath: "/tmp/demo.ipa")
    let out = ReSignModel.resolveOutputURL(for: src, isDirWritable: { _ in true },
                                           downloadsDir: { URL(fileURLWithPath: "/Users/x/Downloads") })
    XCTAssertEqual(out, URL(fileURLWithPath: "/tmp/demo-resigned.ipa"))
}

func testResolveOutputURLFallsBackToDownloadsWhenReadOnly() {
    let src = URL(fileURLWithPath: "/Volumes/DMG/demo.ipa")
    let out = ReSignModel.resolveOutputURL(for: src, isDirWritable: { _ in false },
                                           downloadsDir: { URL(fileURLWithPath: "/Users/x/Downloads") })
    XCTAssertEqual(out, URL(fileURLWithPath: "/Users/x/Downloads/demo-resigned.ipa"))
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter ReSignModelTests/testResolveOutputURL`
Expected: 编译失败（`resolveOutputURL` 未定义）。

- [ ] **Step 3: 实现解析器 + 接入 `resign()`**

在 `ReSignModel` 里新增静态方法：

```swift
/// 产出 IPA 的落点：默认与源同目录 `<原名>-resigned.ipa`；源目录不可写（如挂载只读 DMG）时退回 ~/Downloads。
public static func resolveOutputURL(
    for source: URL,
    isDirWritable: (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) },
    downloadsDir: () -> URL = {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }
) -> URL {
    let name = source.deletingPathExtension().lastPathComponent + "-resigned.ipa"
    let srcDir = source.deletingLastPathComponent()
    if isDirWritable(srcDir.path) { return srcDir.appendingPathComponent(name) }
    return downloadsDir().appendingPathComponent(name)
}
```

在 `resign()` 里，把原本的输出计算：

```swift
let output = ipa.deletingLastPathComponent()
    .appendingPathComponent(ipa.deletingPathExtension().lastPathComponent + "-resigned.ipa")
```

替换为：

```swift
let output = ReSignModel.resolveOutputURL(for: ipa)
if output.deletingLastPathComponent() != ipa.deletingLastPathComponent() {
    log.append("源目录只读，已改输出到下载文件夹")
}
```

- [ ] **Step 4: 跑测试确认通过（含既有流水线用例不回归）**

Run: `swift test --filter ReSignModelTests`
Expected: 全 PASS（`testResignPipelineOrderAndDeviceIds` 仍断言 `/tmp/demo-resigned.ipa`，`/tmp` 可写故不变）。

- [ ] **Step 5: 提交**

```bash
git add Sources/ReSignAppCore/ReSignModel.swift Tests/ReSignAppCoreTests/ReSignModelTests.swift
git commit -m "feat(resignapp): output path resolver with Downloads fallback for read-only source"
```

---

### Task 2: `exportP12`（补齐计划 3 推迟项）

**Files:**
- Modify: `Sources/ReSignAppCore/SigningIdentityManager.swift`
- Modify: `Sources/ReSignAppCore/ReSignModel.swift`
- Test: `Tests/ReSignAppCoreTests/SigningIdentityManagerTests.swift`

**Interfaces:**
- Consumes: `SigningIdentityStore.identity(for:)`、`Subprocess.runChecked`、`SigningIdentity{privateKeyDER,certificateDER,ascCertificateId}`。
- Produces: `SigningIdentityManager.exportP12(for accountID: UUID, password: String) throws -> Data`；`ReSignModel.exportP12(to url: URL, password: String) -> Bool`。

- [ ] **Step 1: 写失败测试**（加到 `SigningIdentityManagerTests`）

```swift
/// 存一套身份 → exportP12 → 用同密码 openssl 解回，证书内容一致、私钥可用
func testExportP12RoundTrips() async throws {
    for t in ["/usr/bin/openssl"] { guard FileManager.default.isExecutableFile(atPath: t) else { throw XCTSkip("no \(t)") } }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    // 造 key(PKCS#1 DER) + 自签证书(DER)，一致成对
    let keyPEM = tmp.appendingPathComponent("k.pem"), keyDER = tmp.appendingPathComponent("k.der")
    let certPEM = tmp.appendingPathComponent("c.pem"), certDER = tmp.appendingPathComponent("c.der")
    func ossl(_ a: [String]) throws { _ = try Subprocess.runChecked("/usr/bin/openssl", a) }
    try ossl(["genrsa", "-out", keyPEM.path, "2048"])
    try ossl(["rsa", "-in", keyPEM.path, "-outform", "DER", "-out", keyDER.path])
    try ossl(["req", "-x509", "-new", "-key", keyPEM.path, "-subj", "/CN=ReSign Export Test", "-days", "1", "-out", certPEM.path])
    try ossl(["x509", "-in", certPEM.path, "-outform", "DER", "-out", certDER.path])
    let privDER = try Data(contentsOf: keyDER), cDER = try Data(contentsOf: certDER)

    let store = InMemorySigningIdentityStore()
    let mgr = SigningIdentityManager(store: store)
    let accID = UUID()
    try store.save(SigningIdentity(privateKeyDER: privDER, certificateDER: cDER, ascCertificateId: "C"), for: accID)

    let p12 = try mgr.exportP12(for: accID, password: "pw")
    XCTAssertFalse(p12.isEmpty)

    // 用同密码解回证书，断言与原证书一致
    let p12URL = tmp.appendingPathComponent("out.p12"); try p12.write(to: p12URL)
    let back = tmp.appendingPathComponent("back.pem")
    _ = try Subprocess.runChecked("/usr/bin/openssl", ["pkcs12", "-in", p12URL.path,
        "-passin", "stdin", "-nokeys", "-clcerts", "-out", back.path], input: Data("pw\n".utf8))
    let backDER = tmp.appendingPathComponent("back.der")
    _ = try Subprocess.runChecked("/usr/bin/openssl", ["x509", "-in", back.path, "-outform", "DER", "-out", backDER.path])
    XCTAssertEqual(try Data(contentsOf: backDER), cDER)
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter SigningIdentityManagerTests/testExportP12RoundTrips`
Expected: 编译失败（`exportP12` 未定义）。

- [ ] **Step 3: 实现 `SigningIdentityManager.exportP12`**

在 `SigningIdentityManager` 里新增（`import Security` 已在文件顶部）：

```swift
/// 从持久化的 SigningIdentity 组回 .p12：openssl 把 PKCS#1 私钥 DER + 证书 DER 拼成 p12。
/// 导出口令走 stdin，不进 argv；明文中间产物用完抹除。
public func exportP12(for accountID: UUID, password: String) throws -> Data {
    guard let id = try store.identity(for: accountID) else { throw SigningIdentityError.badKeyData }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("p12out-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: dir) }
    let keyDER = dir.appendingPathComponent("k.der"), keyPEM = dir.appendingPathComponent("k.pem")
    let certDER = dir.appendingPathComponent("c.der"), certPEM = dir.appendingPathComponent("c.pem")
    let out = dir.appendingPathComponent("out.p12")
    try id.privateKeyDER.write(to: keyDER)
    try id.certificateDER.write(to: certDER)
    do {
        try Subprocess.runChecked("/usr/bin/openssl", ["rsa", "-inform", "DER", "-in", keyDER.path, "-out", keyPEM.path])
        try Subprocess.runChecked("/usr/bin/openssl", ["x509", "-inform", "DER", "-in", certDER.path, "-out", certPEM.path])
        try Subprocess.runChecked("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", keyPEM.path,
            "-in", certPEM.path, "-out", out.path, "-passout", "stdin", "-name", "ReSign Distribution"],
            input: Data((password + "\n").utf8))
    } catch {
        throw SigningIdentityError.p12Import(errSecIO)
    }
    let data = try Data(contentsOf: out)
    for u in [keyPEM, keyDER] {   // 抹掉明文私钥中间产物
        if let n = (try? Data(contentsOf: u))?.count, n > 0 { try? Data(count: n).write(to: u) }
    }
    return data
}
```

- [ ] **Step 4: 实现 `ReSignModel.exportP12` 包装**

在 `ReSignModel` 里新增（对当前选中账号）：

```swift
/// 把当前账号的签名身份导出为 p12 写到用户选的位置。口令不能为空。
public func exportP12(to url: URL, password: String) -> Bool {
    guard let a = selected else { banner = "请先选择账号"; return false }
    guard !password.isEmpty else { banner = "请为导出的 p12 设置一个非空密码"; return false }
    do {
        let data = try identity.exportP12(for: a.id, password: password)
        try data.write(to: url, options: .atomic)
        banner = nil; return true
    } catch { banner = UserFacingMessage.from(error); return false }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --filter SigningIdentityManagerTests`
Expected: 全 PASS。

- [ ] **Step 6: 提交**

```bash
git add Sources/ReSignAppCore/SigningIdentityManager.swift Sources/ReSignAppCore/ReSignModel.swift Tests/ReSignAppCoreTests/SigningIdentityManagerTests.swift
git commit -m "feat(resignapp): exportP12 (openssl-assembled, stdin password)"
```

---

### Task 3: ⚠️ `TemporaryKeychainIdentity` 生产证书泄漏必修

**Files:**
- Modify: `Sources/ReSignKit/TemporaryKeychainIdentity.swift`
- Test: `Tests/ReSignKitTests/TemporaryKeychainIdentityLeakTests.swift`（新建）

**Interfaces:**
- Consumes: 已有 `signingIdentity`（叶证书 SHA-1 hex）、`resolveLoginKeychainPath()`、`Subprocess.run`。
- Produces: import 前把「登录钥匙串是否已含该证书」快照进 `certPreexistedInLogin`；`cleanup()` 里**仅当** `!certPreexistedInLogin` 删一次登录钥匙串副本。行为对外不变（同一 public API）。

- [ ] **Step 1: 写失败测试**（新建 `TemporaryKeychainIdentityLeakTests.swift`）

```swift
import XCTest
import Security
import CryptoKit
import UDIDRegisterKit
@testable import ReSignKit

final class TemporaryKeychainIdentityLeakTests: XCTestCase {
    /// TKI 用完后，登录钥匙串不得残留它导入时新增的证书副本。
    func testCleanupRemovesLeakedCertFromLoginKeychain() throws {
        for t in ["/usr/bin/security", "/usr/bin/openssl"] {
            guard FileManager.default.isExecutableFile(atPath: t) else { throw XCTSkip("missing \(t)") }
        }
        let dir = try TestTemp.dir(); defer { try? FileManager.default.removeItem(at: dir) }

        // 生成 key + 自签「代码签名」证书（不经任何 keychain import，避免污染前置状态）
        let kp = try SigningKeyPair.generateRSA2048()
        var err: Unmanaged<CFError>?
        let privDER = SecKeyCopyExternalRepresentation(kp.privateKey, &err)! as Data
        let keyPEM = dir.appendingPathComponent("k.pem")
        try TestSigningFixture.pkcs1PEM(privDER).write(to: keyPEM, atomically: true, encoding: .utf8)
        let certDERURL = dir.appendingPathComponent("c.der")
        try Subprocess.runChecked("/usr/bin/openssl", ["req", "-x509", "-new", "-key", keyPEM.path,
            "-subj", "/CN=ReSign LeakTest \(UUID().uuidString.prefix(6))", "-days", "1",
            "-outform", "DER", "-out", certDERURL.path,
            "-addext", "keyUsage=critical,digitalSignature",
            "-addext", "extendedKeyUsage=critical,codeSigning",
            "-addext", "basicConstraints=critical,CA:false"])
        let certDER = try Data(contentsOf: certDERURL)
        let sha1 = Insecure.SHA1.hash(data: certDER).map { String(format: "%02X", $0) }.joined()
        // 兜底：断言失败也别把证书留在登录钥匙串
        defer {
            for _ in 0..<8 {
                let r = try? Subprocess.run("/usr/bin/security", ["delete-certificate", "-Z", sha1, "login.keychain-db"])
                if r?.status != 0 { break }
            }
        }

        // 前提：登录钥匙串本来没有这张一次性证书
        let before = try Subprocess.run("/usr/bin/security", ["find-certificate", "-a", "-Z", "login.keychain-db"])
        XCTAssertFalse(before.stdout.uppercased().contains(sha1), "测试前提被破坏：登录钥匙串已含该证书")

        let tki = try TemporaryKeychainIdentity(privateKey: kp.privateKey, certificateDER: certDER, commonName: "ReSign LeakTest")
        tki.cleanup()

        let after = try Subprocess.run("/usr/bin/security", ["find-certificate", "-a", "-Z", "login.keychain-db"])
        XCTAssertFalse(after.stdout.uppercased().contains(sha1), "泄漏未修复：TKI 的证书副本仍在登录钥匙串")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter TemporaryKeychainIdentityLeakTests`
Expected: FAIL（`after` 仍含该 SHA-1——泄漏尚未修复）。

- [ ] **Step 3: 加快照字段 + 两个私有助手**

在 `TemporaryKeychainIdentity` 里，`private var addedToSearchList = false` 附近新增：

```swift
private var certPreexistedInLogin = false   // import 前登录钥匙串是否已有该证书；决定 cleanup 是否删除
```

在 `isTempEntry(_:)` 之后新增两个静态助手：

```swift
/// import 前快照：登录钥匙串是否已含该 SHA-1 的证书。
/// 命令本身失败时保守返回 true（宁可漏删泄漏，也**绝不误删用户真实证书**）。
private static func loginKeychainContainsCert(sha1: String) -> Bool {
    guard let login = try? resolveLoginKeychainPath(), !login.isEmpty else { return true }
    guard let r = try? Subprocess.run("/usr/bin/security", ["find-certificate", "-a", "-Z", login]),
          r.status == 0 else { return true }
    return r.stdout.uppercased().contains(sha1)
}
/// 从登录钥匙串删掉该 SHA-1 的证书（只在 import 前不存在时调用——即只删我们新增那份）。
private static func deleteLoginKeychainLeak(sha1: String) {
    guard let login = try? resolveLoginKeychainPath(), !login.isEmpty else { return }
    _ = try? Subprocess.run("/usr/bin/security", ["delete-certificate", "-Z", sha1, login])
}
```

- [ ] **Step 4: init 里 import 前快照**

在 `init` 的 `do` 块中，**紧接在** `security import` 调用（`["import", p12URL.path, "-k", keychainPath, ...]`）**之前**插入一行：

```swift
// 快照：import 会往登录钥匙串泄漏一份证书副本；记录它此刻是否已存在，供 cleanup 决定是否删除。
self.certPreexistedInLogin = TemporaryKeychainIdentity.loginKeychainContainsCert(sha1: signingIdentity)
```

- [ ] **Step 5: cleanup 里条件删除**

在 `cleanup()` 中，`delete-keychain` 那一行**之后**插入：

```swift
// 只删「我们导入时新增那份」：import 前登录钥匙串没有才删，绝不碰用户自己的证书。
if !certPreexistedInLogin {
    Self.deleteLoginKeychainLeak(sha1: signingIdentity)
}
```

- [ ] **Step 6: 跑测试确认通过 + 全量回归**

Run: `swift test --filter TemporaryKeychainIdentityLeakTests`
Expected: PASS。
Run: `swift test`
Expected: 全绿（新增用例后总数增加，无回归）。

- [ ] **Step 7: 提交**

```bash
git add Sources/ReSignKit/TemporaryKeychainIdentity.swift Tests/ReSignKitTests/TemporaryKeychainIdentityLeakTests.swift
git commit -m "fix(resignkit): stop leaking real dist cert into login keychain (snapshot-before-import, delete only our copy)"
```

---

### Task 4: `ReSignModel.live()` 生产接线（与注册 app 隔离）

**Files:**
- Create: `Sources/ReSignAppCore/ReSignModelLive.swift`
- Test: `Tests/ReSignAppCoreTests/ReSignModelTests.swift`

**Interfaces:**
- Consumes: `AccountStore(fileURL:)`、`KeychainSecretStore(service:)`、`KeychainSigningIdentityStore()`、`ASCClient(http:)`、`URLSessionHTTPClient()`、`ReSignAppIdentifiers.bundleID`。
- Produces: `ReSignModel.live() -> ReSignModel`、`ReSignModel.liveAccountsFileURL() -> URL`。

- [ ] **Step 1: 写冒烟测试**（加到 `ReSignModelTests`）

```swift
func testLiveAccountsFileURLIsResignScopedAndSeparateFromRegisterApp() {
    let url = ReSignModel.liveAccountsFileURL()
    XCTAssertEqual(url.lastPathComponent, "accounts.json")
    XCTAssertTrue(url.deletingLastPathComponent().lastPathComponent == "ReSignMac",
                  "ReSignApp 账号库必须独立目录，实际：\(url.path)")
    XCTAssertFalse(url.path.contains("/UDIDRegisterMac/"), "不得与注册 app 共用账号文件")
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter ReSignModelTests/testLiveAccountsFileURLIsResignScoped`
Expected: 编译失败（`liveAccountsFileURL` 未定义）。

- [ ] **Step 3: 实现 live 工厂**（新建 `ReSignModelLive.swift`）

```swift
import Foundation
import UDIDRegisterKit
import ReSignKit

extension ReSignModel {
    /// ReSignApp 专属账号文件（与注册 app 的 UDIDRegisterMac 目录分开）。
    public static func liveAccountsFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReSignMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("accounts.json")
    }

    /// 生产接线：ReSignApp 自己的账号库 + 钥匙串 service（`com.pangu.ReSignMac`）+ 签名身份库 + 真实 ASCClient。
    @MainActor public static func live() -> ReSignModel {
        ReSignModel(
            store: AccountStore(fileURL: liveAccountsFileURL()),
            secrets: KeychainSecretStore(service: ReSignAppIdentifiers.bundleID),
            identity: SigningIdentityManager(store: KeychainSigningIdentityStore()),
            client: ASCClient(http: URLSessionHTTPClient()))
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter ReSignModelTests`
Expected: 全 PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/ReSignAppCore/ReSignModelLive.swift Tests/ReSignAppCoreTests/ReSignModelTests.swift
git commit -m "feat(resignapp): ReSignModel.live() wiring, isolated from register app data"
```

---

### Task 5: `@main` + AppDelegate + 可启动骨架窗口

**Files:**
- Delete: `Sources/ReSignApp/main.swift`
- Create: `Sources/ReSignApp/ReSignApp.swift`
- Create: `Sources/ReSignApp/ReSignRootView.swift`（本任务先做「账号 Picker + 管理入口」骨架，Task 6 补全）

**Interfaces:**
- Consumes: `ReSignModel.live()`、`ReSignModel`（`@Observable`）。
- Produces: 可 `swift run ReSignApp` 出窗口的 SwiftUI app。

- [ ] **Step 1: 删占位、建 `@main`**

删除 `Sources/ReSignApp/main.swift`。新建 `Sources/ReSignApp/ReSignApp.swift`：

```swift
import SwiftUI
import AppKit
import ReSignAppCore

@main
struct ReSignApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = ReSignModel.live()
    var body: some Scene {
        WindowGroup("重签助手") {
            ReSignRootView().environment(model)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)      // SPM 可执行需显式设常规 app 才有 Dock 图标/前台窗口
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
```

- [ ] **Step 2: 建骨架 RootView**（`Sources/ReSignApp/ReSignRootView.swift`）

```swift
import SwiftUI
import ReSignAppCore
import UDIDRegisterKit

struct ReSignRootView: View {
    @Environment(ReSignModel.self) private var model
    @State private var showAccounts = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("账号").font(.subheadline)
                Picker("账号", selection: $model.selectedID) {
                    ForEach(model.accounts) { a in Text(a.displayName).tag(Optional(a.id)) }
                }
                .labelsHidden().frame(maxWidth: 240)
                Button("管理账号…") { showAccounts = true }
                Spacer()
            }
            if model.selected == nil {
                Text("请先在「管理账号…」里导入一个账号配置文件").foregroundStyle(.secondary)
            }
            if let banner = model.banner {
                Text(banner).font(.callout).foregroundStyle(.red)
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 520, alignment: .topLeading)
        .sheet(isPresented: $showAccounts) { AccountsSheet().environment(model) }
    }
}
```

> 注：`AccountsSheet` 在 Task 6 建。本任务为让骨架能编译，先临时用一个占位：在 `ReSignRootView.swift` 末尾加
> ```swift
> struct AccountsSheet: View { var body: some View { Text("账号管理（Task 6 补全）").padding() } }
> ```
> Task 6 会把它替换为独立文件里的完整实现（届时删掉这个占位）。

- [ ] **Step 3: 编译 + 启动冒烟**

Run: `swift build --product ReSignApp`
Expected: 编译通过。
Run: `swift run ReSignApp`（手动确认弹出窗口后 Ctrl-C 退出；若在无 GUI 环境，至少确认进程启动无崩溃日志）
Expected: 出现「重签助手」窗口，含账号 Picker + 管理账号按钮。

- [ ] **Step 4: 提交**

```bash
git add -A Sources/ReSignApp
git commit -m "feat(resignapp): @main SwiftUI app + AppDelegate + skeleton root view"
```

---

### Task 6: 完整 RootView（签名身份 / IPA / 一键重签 / 日志）+ 账号与密码 Sheet

**Files:**
- Modify: `Sources/ReSignApp/ReSignRootView.swift`（补全签名身份区、IPA 区、重签区、日志；删占位 `AccountsSheet`）
- Create: `Sources/ReSignApp/AccountsSheet.swift`
- Create: `Sources/ReSignApp/PasswordSheet.swift`

**Interfaces:**
- Consumes: `ReSignModel`：`identityStatus(for:)`、`createIdentity()`、`importP12(from:password:)`、`exportP12(to:password:)`、`importAccountConfig(from:)`、`deleteAccount(id:)`、`resign()`、`selectedIPA`、`log`、`busy`、`banner`、`accounts`、`selected`、`selectedID`。
- Produces: 完整可操作单窗口 UI。

- [ ] **Step 1: 密码 Sheet**（`Sources/ReSignApp/PasswordSheet.swift`）

```swift
import SwiftUI

/// 通用密码输入小 sheet：确认回调带回明文密码，取消回调无参。
struct PasswordSheet: View {
    let title: String
    let confirmLabel: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            SecureField("密码", text: $password)
                .textFieldStyle(.roundedBorder).frame(width: 280)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { onCancel() }
                Button(confirmLabel) { onConfirm(password) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 340)
    }
}
```

- [ ] **Step 2: 账号 Sheet**（`Sources/ReSignApp/AccountsSheet.swift`）

```swift
import SwiftUI
import AppKit
import ReSignAppCore
import UDIDRegisterKit

/// 账号管理：导入配置文件 / 列表 / 删除。复用 ReSignModel 的 importAccountConfig / deleteAccount。
struct AccountsSheet: View {
    @Environment(ReSignModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("管理账号").font(.headline)
            List {
                ForEach(model.accounts) { a in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(a.displayName)
                            Text(a.issuerID).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { model.deleteAccount(id: a.id) } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless)
                    }
                }
            }.frame(minHeight: 160)
            HStack {
                Button {
                    importConfig()
                } label: { Label("导入账号配置文件…", systemImage: "square.and.arrow.down") }
                .disabled(importing)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if let banner = model.banner { Text(banner).font(.caption).foregroundStyle(.red) }
        }
        .padding(20).frame(width: 460)
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择注册助手导出的账号配置文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        Task { _ = await model.importAccountConfig(from: url); importing = false }
    }
}
```

- [ ] **Step 3: 补全 RootView**（替换 `ReSignRootView.swift` 全文；删掉 Task 5 的占位 `AccountsSheet`）

```swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ReSignAppCore
import UDIDRegisterKit

struct ReSignRootView: View {
    @Environment(ReSignModel.self) private var model
    @State private var showAccounts = false
    @State private var pwSheet: PasswordAction?

    enum PasswordAction: Identifiable {
        case importP12(URL), exportP12(URL)
        var id: String { switch self { case .importP12(let u): return "in:\(u.path)"; case .exportP12(let u): return "out:\(u.path)" } }
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            accountRow(model)
            Divider()
            identitySection
            Divider()
            ipaSection
            resignSection
            logSection
            if let banner = model.banner { Text(banner).font(.callout).foregroundStyle(.red) }
        }
        .padding()
        .frame(minWidth: 660, minHeight: 560, alignment: .topLeading)
        .sheet(isPresented: $showAccounts) { AccountsSheet().environment(model) }
        .sheet(item: $pwSheet) { action in passwordSheet(for: action) }
    }

    @ViewBuilder private func accountRow(_ model: ReSignModel) -> some View {
        @Bindable var model = model
        HStack {
            Text("账号").font(.subheadline)
            Picker("账号", selection: $model.selectedID) {
                ForEach(model.accounts) { a in Text(a.displayName).tag(Optional(a.id)) }
            }.labelsHidden().frame(maxWidth: 240)
            Button("管理账号…") { showAccounts = true }
            Spacer()
        }
        if model.selected == nil {
            Text("请先在「管理账号…」里导入一个账号配置文件").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var identitySection: some View {
        let ready = model.selected.map { model.identityStatus(for: $0.id) == .ready } ?? false
        HStack(spacing: 10) {
            Label(ready ? "签名身份已就绪" : "尚未创建签名身份",
                  systemImage: ready ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ready ? .green : .orange)
            Spacer()
            Button("自动创建") { Task { _ = await model.createIdentity() } }
                .disabled(model.selected == nil || model.busy)
            Button("导入 p12…") { pickP12ToImport() }
                .disabled(model.selected == nil || model.busy)
            Button("导出 p12…") { pickP12ToExport() }
                .disabled(!ready || model.busy)
        }
    }

    @ViewBuilder private var ipaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("IPA").font(.subheadline)
                Spacer()
                Button("选择 IPA…") { pickIPA() }
            }
            RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .frame(height: 64).foregroundStyle(.secondary.opacity(0.5))
                .overlay(Text(model.selectedIPA?.lastPathComponent ?? "把 .ipa 拖到这里，或点「选择 IPA…」")
                    .foregroundStyle(.secondary))
                .dropDestination(for: URL.self) { urls, _ in
                    guard let u = urls.first(where: { $0.pathExtension.lowercased() == "ipa" }) else { return false }
                    model.selectedIPA = u; return true
                }
        }
    }

    @ViewBuilder private var resignSection: some View {
        HStack {
            Button {
                Task { await model.resign() }
            } label: {
                Label("一键重签", systemImage: "signature").frame(maxWidth: .infinity)
            }
            .controlSize(.large).buttonStyle(.borderedProminent)
            .disabled(model.busy || model.selected == nil || model.selectedIPA == nil)
            if model.busy { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder private var logSection: some View {
        if !model.log.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: 140)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
        }
    }

    // MARK: - 面板

    private func pickIPA() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        if let ipa = UTType(filenameExtension: "ipa") { panel.allowedContentTypes = [ipa] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.selectedIPA = url
    }
    private func pickP12ToImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        if let p12 = UTType(filenameExtension: "p12") { panel.allowedContentTypes = [p12] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pwSheet = .importP12(url)
    }
    private func pickP12ToExport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(model.selected?.displayName ?? "identity").p12"
        if let p12 = UTType(filenameExtension: "p12") { panel.allowedContentTypes = [p12] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pwSheet = .exportP12(url)
    }

    @ViewBuilder private func passwordSheet(for action: PasswordAction) -> some View {
        switch action {
        case .importP12(let url):
            PasswordSheet(title: "输入 p12 密码", confirmLabel: "导入",
                          onConfirm: { pw in pwSheet = nil; Task { _ = await model.importP12(from: url, password: pw) } },
                          onCancel: { pwSheet = nil })
        case .exportP12(let url):
            PasswordSheet(title: "为导出的 p12 设置密码", confirmLabel: "导出",
                          onConfirm: { pw in pwSheet = nil; _ = model.exportP12(to: url, password: pw) },
                          onCancel: { pwSheet = nil })
        }
    }
}
```

- [ ] **Step 4: 编译 + 启动冒烟**

Run: `swift build --product ReSignApp`
Expected: 编译通过。
Run: `swift run ReSignApp`（手动点开：管理账号 sheet 打开、身份徽章按选中账号变化、拖入/选择 IPA 显示文件名、密码 sheet 弹出；确认无崩溃）
Expected: 各控件可交互，无签名身份/未选 IPA 时「一键重签」禁用。

- [ ] **Step 5: 全量测试回归**

Run: `swift test`
Expected: 全绿（UI 不含单测，逻辑测试不受影响）。

- [ ] **Step 6: 提交**

```bash
git add -A Sources/ReSignApp
git commit -m "feat(resignapp): full root view — identity/IPA/one-tap-resign/log + account & password sheets"
```

---

### Task 7: 区分图标 `Resources/ReSignAppIcon.icns`

**Files:**
- Modify: `scripts/make-icon.swift`
- Create: `Resources/ReSignAppIcon.icns`（脚本产物）

**Interfaces:**
- Produces: `Resources/ReSignAppIcon.icns`（配色/字形区别于注册 app）；`scripts/make-icon.swift` 支持第二个变体（不破坏既有 `AppIcon.icns` 产出）。

- [ ] **Step 1: 让 make-icon 支持变体**

把 `render(px:)` 增加一个「主题」入参，并在末尾按参数决定输出到哪套 iconset/icns。改 `scripts/make-icon.swift`：

`render` 函数签名改为 `func render(px: Int, accent: (CGFloat, CGFloat, CGFloat)) -> Data`，把背景渐变的两个 `CGColor` 用 `accent` 派生（ReSignApp 用青绿主题以区分注册 app 的蓝紫）：

```swift
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [CGColor(red: accent.0, green: accent.1, blue: accent.2, alpha: 1),
             CGColor(red: max(0, accent.0-0.1), green: max(0, accent.1-0.05), blue: max(0, accent.2-0.2), alpha: 1)] as CFArray,
    locations: [0, 1])!
```

并把「右下角徽章」从绿色对勾改为「循环/重签」字形（两段带箭头的弧线）以示区别——用现有 `ctx` 绘图 API 画一个 `↻`：

```swift
// 重签徽章：蓝色圆底 + 白色回环箭头
ctx.setFillColor(CGColor(red: 0.13, green: 0.45, blue: 0.95, alpha: 1))
ctx.fillEllipse(in: badge)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.setLineWidth(s*0.022); ctx.setLineCap(.round)
ctx.addArc(center: CGPoint(x: bcx, y: bcy), radius: br*0.5,
           startAngle: .pi*0.15, endAngle: .pi*1.7, clockwise: false)
ctx.strokePath()
// 箭头头
ctx.beginPath()
ctx.move(to: CGPoint(x: bcx + br*0.5, y: bcy + br*0.05))
ctx.addLine(to: CGPoint(x: bcx + br*0.5, y: bcy - br*0.28))
ctx.addLine(to: CGPoint(x: bcx + br*0.85, y: bcy - br*0.05))
ctx.strokePath()
```

在文件末尾把「输出段」改为按命令行参数选变体：

```swift
let variant = CommandLine.arguments.dropFirst().first ?? "register"
let (accent, iconset, icns): ((CGFloat,CGFloat,CGFloat), String, String) =
    variant == "resign"
      ? ((0.10, 0.72, 0.60), "Resources/ReSignAppIcon.iconset", "Resources/ReSignAppIcon.icns")
      : ((0.31, 0.40, 0.96), "Resources/AppIcon.iconset", "Resources/AppIcon.icns")
```

（把后续 `render(px:)` 调用改为 `render(px:, accent: accent)`，`iconset`/`-o` 路径改用上面的变量。）

- [ ] **Step 2: 生成两版图标并确认无破坏**

Run: `swift scripts/make-icon.swift` （默认 register 变体，应重现原 `Resources/AppIcon.icns`）
Run: `swift scripts/make-icon.swift resign`
Expected: 两条都打印「✅ ... 生成成功」；`Resources/ReSignAppIcon.icns` 生成。
Run: `git status --short Resources/AppIcon.icns`
Expected: 若默认变体产物与既有一致则无改动；若有极小差异（渐变派生），目视两图标可区分即可接受。

- [ ] **Step 3: 提交**

```bash
git add scripts/make-icon.swift Resources/ReSignAppIcon.icns Resources/ReSignAppIcon.iconset
git commit -m "feat(resignapp): distinct teal app icon via parametrized make-icon"
```

---

### Task 8: Info.plist + entitlements + `scripts/package-resign.sh`

**Files:**
- Create: `Resources/ReSignApp-Info.plist`
- Create: `Resources/ReSignApp.entitlements`
- Create: `scripts/package-resign.sh`

**Interfaces:**
- Consumes: `Sources/ReSignAppCore/ReSignAppIdentifiers.swift`（抽 bundle id）、`Resources/ReSignAppIcon.icns`（Task 7）。
- Produces: `dist/ReSignMac.dmg`（本地跑到 codesign；公证由用户跑）。

- [ ] **Step 1: Info.plist**（`Resources/ReSignApp-Info.plist`）

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>重签助手</string>
<key>CFBundleDisplayName</key><string>重签助手</string>
<key>CFBundleIdentifier</key><string>com.pangu.ReSignMac</string>
<key>CFBundleExecutable</key><string>ReSignApp</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>ReSignAppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
```

> `CFBundleIdentifier` 打包脚本会用 `ReSignAppIdentifiers.swift` 抽出的值覆盖，此处的值仅为占位默认。

- [ ] **Step 2: entitlements（不沙盒、最小）**（`Resources/ReSignApp.entitlements`）

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
```

> 故意空字典：ReSignApp 需 spawn `codesign`/`security`/`ditto`，**不能**带 `app-sandbox`；硬化运行时由 `codesign --options runtime` 提供。它们是独立子进程（非动态库加载），无需 `cs.*` 例外。

- [ ] **Step 3: 打包脚本**（`scripts/package-resign.sh`，独立于 `package.sh`）

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# 需要环境变量：DEV_ID_APP="Developer ID Application: NAME (TEAMID)"，NOTARY_PROFILE=公证 keychain profile 名
APP="ReSignMac.app"
BIN="ReSignApp"
DIST="dist"

# bundle-id 单一来源：从 ReSignAppIdentifiers.swift 抽取，保证与 Keychain service 一致
BUNDLE_ID=$(grep -Eo 'bundleID[[:space:]]*=[[:space:]]*"[^"]+"' Sources/ReSignAppCore/ReSignAppIdentifiers.swift | sed -E 's/.*"([^"]+)".*/\1/')
[ -n "$BUNDLE_ID" ] || { echo "❌ 无法从 ReSignAppIdentifiers.swift 解析 bundleID"; exit 1; }
echo "Bundle ID: $BUNDLE_ID"

[ -f Resources/ReSignAppIcon.icns ] || { echo "❌ 缺少 Resources/ReSignAppIcon.icns，请先运行 swift scripts/make-icon.swift resign"; exit 1; }

swift build -c release --product "$BIN"

rm -rf "$DIST/$APP"; mkdir -p "$DIST/$APP/Contents/MacOS" "$DIST/$APP/Contents/Resources"
cp ".build/release/$BIN" "$DIST/$APP/Contents/MacOS/$BIN"
cp Resources/ReSignAppIcon.icns "$DIST/$APP/Contents/Resources/ReSignAppIcon.icns"

cp Resources/ReSignApp-Info.plist "$DIST/$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$DIST/$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $BIN" "$DIST/$APP/Contents/Info.plist"

codesign --force --options runtime --timestamp \
  --entitlements Resources/ReSignApp.entitlements \
  --sign "$DEV_ID_APP" "$DIST/$APP"

# ---- 生成带「拖入 应用程序」布局的 DMG ----
VOL="重签助手"
STAGE="$DIST/dmg-stage-resign"
RW="$DIST/rw-resign.dmg"
FINAL="$DIST/ReSignMac.dmg"

hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true
rm -rf "$STAGE" "$RW" "$FINAL"
mkdir -p "$STAGE"
cp -R "$DIST/$APP" "$STAGE/$APP"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
DEV=$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | grep -Eo '^/dev/disk[0-9]+' | head -1)

osascript <<OSA || echo "（提示：窗口布局未设置——在弹窗里允许「控制 Finder」后重跑；DMG 仍可正常拖拽安装）"
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 720, 470}
    set vopts to the icon view options of container window
    set arrangement of vopts to not arranged
    set icon size of vopts to 96
    set position of item "$APP" of container window to {150, 175}
    set position of item "Applications" of container window to {380, 175}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA

sync
hdiutil detach "$DEV" >/dev/null 2>&1 || hdiutil detach "$DEV" -force >/dev/null 2>&1 || true
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$FINAL" >/dev/null
rm -f "$RW"; rm -rf "$STAGE"

# ---- 公证 + staple（需 NOTARY_PROFILE）----
xcrun notarytool submit "$FINAL" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$FINAL"
echo "✅ 完成：$FINAL"
```

- [ ] **Step 4: 本地跑到 codesign（不公证）验证脚本正确**

Run（本地冒烟，不设 `NOTARY_PROFILE` 也能跑到打包前）：
```bash
chmod +x scripts/package-resign.sh
DEV_ID_APP="${DEV_ID_APP:-}" bash -c '
  set -e
  swift build -c release --product ReSignApp
  echo "release build ok: $(ls -la .build/release/ReSignApp | awk "{print \$5}") bytes"
'
```
Expected: release 产物生成成功。（完整 `codesign`/`hdiutil`/公证需真实 `DEV_ID_APP`+`NOTARY_PROFILE`，见 Task 9 交付说明——由用户执行。）

- [ ] **Step 5: 提交**

```bash
git add Resources/ReSignApp-Info.plist Resources/ReSignApp.entitlements scripts/package-resign.sh
git commit -m "build(resignapp): non-sandboxed Info.plist + entitlements + package-resign.sh (DMG + notarize)"
```

---

### Task 9: 全量验证 + 交接更新

**Files:**
- Modify: `docs/superpowers/plans/2026-07-17-resign-progress-handoff.md`（或新增次日 handoff）
- Modify: `.superpowers/sdd/progress.md`（台账，gitignored）

**Interfaces:** 无代码接口；收尾与交付说明。

- [ ] **Step 1: 全量构建 + 测试**

Run: `swift build`
Run: `swift test`
Expected: 均成功；测试全绿（原 90 + 本计划新增用例）。

- [ ] **Step 2: 启动冒烟复核**

Run: `swift run ReSignApp`
Expected: 窗口正常，账号/身份/IPA/重签/日志各区可交互（无真账号时仅验证 UI 流转与禁用态）。

- [ ] **Step 3: 更新交接文档**

在 handoff 里记录：计划 4 已完成（A–E），泄漏已修并有集成测试；**待用户执行**两步——
1. **公证打包**：`export DEV_ID_APP="Developer ID Application: … (TEAMID)"; export NOTARY_PROFILE=<profile>; scripts/package-resign.sh` → 得 `dist/ReSignMac.dmg`。
2. **真机 E2E 验收**：导入真账号配置 → 自动创建或导入 p12 → 选真 IPA → 一键重签 → 用 Apple Configurator 装到测试机成功。

- [ ] **Step 4: 提交**

```bash
git add docs/superpowers/plans/2026-07-17-resign-progress-handoff.md
git commit -m "docs(resignapp): plan 4 done — handoff for user notarization + device E2E"
```

- [ ] **Step 5: 收尾**

进入 `superpowers:finishing-a-development-branch` 决定分支去向（合并 / PR / 保留）。

---

## Self-Review

**Spec coverage（对照 spec 的「计划 4 决策增量」A–F）：**
- A 输出路径 → Task 1 ✓
- B 泄漏必修 → Task 3 ✓
- C exportP12 → Task 2 ✓
- D SwiftUI + @main + live 接线 → Task 4/5/6 ✓
- E 图标 + 打包 → Task 7/8 ✓
- F 范围与验证 → Task 9 ✓（公证/真机 E2E 明确交用户）

**Placeholder scan：** 每个代码步骤均给出完整代码/命令；Task 5 的临时 `AccountsSheet` 占位在 Task 6 明确删除并替换，非遗留 TODO。

**Type consistency：** `resolveOutputURL`、`exportP12(for:password:)` / `exportP12(to:password:)`、`live()` / `liveAccountsFileURL()`、`certPreexistedInLogin` / `loginKeychainContainsCert` / `deleteLoginKeychainLeak`、`ReSignRootView` / `AccountsSheet` / `PasswordSheet` / `PasswordAction` 在各任务间签名一致。`ReSignModel` 消费的方法（createIdentity/importP12/exportP12/resign/identityStatus/importAccountConfig/deleteAccount）均为其现有或本计划新增的 public 成员。
</content>
</invoke>
