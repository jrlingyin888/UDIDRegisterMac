# 注入接入一键重签 + 插件选择 + 打包（Phase C2）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在「重签助手」里让用户可选一个插件 dylib，一键完成「注入 + 通配签名（含扩展）→ 可装 IPA」；内置 insert_dylib/ElleKit 随 app 打包、运行时可定位。不选插件时行为与现状完全一致。

**Architecture:** 复用已验证的 `DylibInjector` 链路（PoC + 真机 M3 通过）。`ReSignModel` 加 `selectedPlugin` 状态 + 可注入 `performInjection` 闭包（解包→注入→重打包，返回临时 IPA），`resign()` 选了插件就先注入再把产物交给现有 `performResign`。内置工具用双路径解析器 `BundledInjectTools`（打包后 `Bundle.main` / dev·测试 CWD）定位。UI 在 IPA 行下加可选插件行。

**Tech Stack:** Swift 5.9 / SwiftPM / macOS 14；`ditto`/`xattr`/`codesign`（子进程）；内置 `insert_dylib` + `ElleKit.dylib`（已提交 `Resources/inject/`）；SwiftUI（`ReSignApp`）。

## Global Constraints

- 平台 `macOS(.v14)`，`swift-tools-version: 5.9`，保持 `swift test` 全绿。
- 输入 IPA 必须已解密（`cryptid==0`）、仅 arm64、只往干净（未注入）app 注入。违反 → 中文 banner，不产出半成品。
- 注入位置 `Payload/<App>.app/Frameworks/`；插件对 CydiaSubstrate 的依赖自动改指内置 ElleKit（`DylibInjector.inject` 已实现）。
- FakeGPS/ElleKit 只进主 app，扩展不注入。
- 不选插件时 `resign()` 行为与现状**逐字节一致**（输出仍 `-resigned.ipa`）。
- 用户可见文案中文。
- `Resources/inject/` 文件**保持原地不迁移**（避免动已评审的 `DylibInjectorTests`）。

## 文件结构

- Create `Sources/ReSignAppCore/BundledInjectTools.swift`：内置工具双路径解析器。
- Modify `Sources/ReSignAppCore/ReSignModel.swift`：加 `selectedPlugin` + `performInjection` + `defaultPerformInjection` + `resolveOutputURL(injected:)` + `resign()` 注入分支。
- Modify `Sources/ReSignApp/ReSignRootView.swift`：加插件选择行 + 按钮文案。
- Modify `scripts/package-resign.sh`：拷 `Resources/inject` 进 app + 各自 hardened-runtime 签名（过公证）。
- Test `Tests/ReSignAppCoreTests/BundledInjectToolsTests.swift`（新）、扩展 `Tests/ReSignAppCoreTests/ReSignModelTests.swift`。
- Modify `Tests/ReSignAppCoreTests/InjectionPoCTests.swift`：工具定位改用 `BundledInjectTools`。

---

### Task 1: `BundledInjectTools` + 打包内置工具

**Files:**
- Create: `Sources/ReSignAppCore/BundledInjectTools.swift`
- Test: `Tests/ReSignAppCoreTests/BundledInjectToolsTests.swift`
- Modify: `scripts/package-resign.sh`, `Tests/ReSignAppCoreTests/InjectionPoCTests.swift`

**Interfaces:**
- Consumes: `Bundle.main`、`FileManager`、`ReSignAppError.msg`（现有，`ReSignAppCore/ReSignModel.swift`）、`MachOInspect.archs`（`ReSignKit`，公开）。
- Produces:
  - `enum BundledInjectTools { static var insertDylib: URL { get throws }; static var ellekit: URL { get throws } }`
  - 打包脚本把 `Resources/inject/{insert_dylib,ElleKit.dylib}` 附进 `.app/Contents/Resources/inject/` 并各自签名。

- [ ] **Step 1: 写 `BundledInjectTools` 的失败测试**

Create `Tests/ReSignAppCoreTests/BundledInjectToolsTests.swift`:
```swift
import XCTest
@testable import ReSignAppCore
import ReSignKit

final class BundledInjectToolsTests: XCTestCase {
    func testResolvesBundledInsertDylibAndEllekit() throws {
        let insert = try BundledInjectTools.insertDylib
        let elle = try BundledInjectTools.ellekit
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: insert.path),
                      "insert_dylib 应可执行：\(insert.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: elle.path),
                      "ElleKit.dylib 应存在：\(elle.path)")
        let archs = try MachOInspect.archs(elle)
        XCTAssertTrue(archs.contains("arm64"), "ElleKit.dylib 应含 arm64，实际：\(archs)")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter BundledInjectToolsTests`
Expected: 编译失败（`BundledInjectTools` 未定义）。

- [ ] **Step 3: 实现 `BundledInjectTools`**

Create `Sources/ReSignAppCore/BundledInjectTools.swift`:
```swift
import Foundation

/// 定位随 app 打包的注入工具（insert_dylib）与运行时（ElleKit.dylib）。
/// 打包后从 app bundle 的 Resources/inject/ 取；dev/测试（`swift run`/`swift test`，CWD=包根）
/// 从仓库 Resources/inject/ 取。两处都找不到则抛中文错误。
public enum BundledInjectTools {
    public static var insertDylib: URL { get throws { try tool("insert_dylib") } }
    public static var ellekit: URL { get throws { try tool("ElleKit.dylib") } }

    static func tool(_ name: String) throws -> URL {
        // ① 打包后的 app：Contents/Resources/inject/<name>
        if let res = Bundle.main.resourceURL {
            let u = res.appendingPathComponent("inject/\(name)")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        // ② dev/测试：<CWD>/Resources/inject/<name>
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/inject/\(name)")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        throw ReSignAppError.msg("找不到内置注入工具：\(name)（打包时未随 app 附带）")
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter BundledInjectToolsTests`
Expected: PASS（dev 环境经 ② 分支命中仓库 `Resources/inject/`）。

- [ ] **Step 5: 迁 `InjectionPoCTests` 的工具定位到 `BundledInjectTools`**

在 `Tests/ReSignAppCoreTests/InjectionPoCTests.swift` 中：删除私有方法 `bundledInjectTool(_:)`（`private func bundledInjectTool...` 整段）；把
```swift
        let insertTool = bundledInjectTool("insert_dylib")
        let ellekit = bundledInjectTool("ElleKit.dylib")
        guard FileManager.default.isExecutableFile(atPath: insertTool.path) else { throw XCTSkip("缺自带 insert_dylib（Task 1）") }
        guard FileManager.default.fileExists(atPath: ellekit.path) else { throw XCTSkip("缺自带 ElleKit.dylib（Task 1）") }
```
替换为：
```swift
        let insertTool = try BundledInjectTools.insertDylib
        let ellekit = try BundledInjectTools.ellekit
```

- [ ] **Step 6: 改 `package-resign.sh` —— 附带内置工具 + 各自签名**

在 `scripts/package-resign.sh` 中，紧跟 icon 拷贝那行（`cp Resources/ReSignAppIcon.icns ...`）之后、Info.plist 处理之前，插入：
```bash
# 内置注入工具随 app 附带；为过公证，Mach-O 需各自 hardened-runtime + 时间戳签名
[ -f Resources/inject/insert_dylib ] && [ -f Resources/inject/ElleKit.dylib ] || { echo "❌ 缺 Resources/inject 内置工具"; exit 1; }
cp -R Resources/inject "$DIST/$APP/Contents/Resources/inject"
codesign --force --options runtime --timestamp --sign "$DEV_ID_APP" "$DIST/$APP/Contents/Resources/inject/insert_dylib"
codesign --force --options runtime --timestamp --sign "$DEV_ID_APP" "$DIST/$APP/Contents/Resources/inject/ElleKit.dylib"
```
（主 app 的 `codesign`（现有那行）随后封入整个 bundle。）

- [ ] **Step 7: 校验脚本 + 全量回归**

Run:
```bash
bash -n scripts/package-resign.sh && echo "语法 OK"
swift test
```
Expected: `语法 OK`；`swift test` 全绿（新 `BundledInjectToolsTests` 通过；gated PoC 仍默认跳过）。

- [ ] **Step 8: 提交**

```bash
git add Sources/ReSignAppCore/BundledInjectTools.swift Tests/ReSignAppCoreTests/BundledInjectToolsTests.swift Tests/ReSignAppCoreTests/InjectionPoCTests.swift scripts/package-resign.sh
git commit -m "feat(resignappcore): BundledInjectTools locate insert_dylib/ElleKit (packaged app + dev fallback); package-resign bundles+signs them"
```

---

### Task 2: 模型注入分支（`defaultPerformInjection` + `resign()` 接线）

**Files:**
- Modify: `Sources/ReSignAppCore/ReSignModel.swift`
- Test: `Tests/ReSignAppCoreTests/ReSignModelTests.swift`

**Interfaces:**
- Consumes: `BundledInjectTools.insertDylib/ellekit`（Task 1）；`DylibInjector.preflight/inject`、`IPAResigner.findPayloadApp`、`Subprocess`（`ReSignKit`，公开）；现有 `performResign` 闭包、`resolveOutputURL`、`buildAdHocProfile`。
- Produces:
  - `ReSignModel.selectedPlugin: URL?`
  - `ReSignModel.performInjection: (_ ipaURL: URL, _ plugin: URL) throws -> URL`（默认 `defaultPerformInjection`）
  - `static func defaultPerformInjection(ipaURL: URL, plugin: URL) throws -> URL`
  - `resolveOutputURL(for:injected:...)` 加 `injected: Bool = false`（`injected` 时后缀 `-injected.ipa`）
  - `resign()` 选了插件时先注入再签。

- [ ] **Step 1: 写失败测试 —— 注入编排 + 输出命名**

在 `Tests/ReSignAppCoreTests/ReSignModelTests.swift` 追加两个测试（`makeModel` 与 `MockHTTP` 套路同 `testResignPipelineOrderAndDeviceIds`）：
```swift
    /// 选了插件 → resign() 先调 performInjection，把其产物（而非原 IPA）交给 performResign；输出名 -injected.ipa
    func testResignInjectsWhenPluginSelectedAndNamesInjected() async throws {
        let profileData = Data([0xAB])
        let mock = MockHTTP { method, path in
            if path.hasSuffix("v1/bundleIds") {
                return method == "GET" ? MockHTTP.json(200, ["data": []])
                    : MockHTTP.json(201, ["data": ["id": "B1", "attributes": ["identifier": "com.demo.app", "name": "com.demo.app"]]])
            }
            if path.hasSuffix("v1/devices") { return MockHTTP.json(200, ["data": [["id": "D1", "attributes": ["udid": "u1", "name": "d1", "status": "ENABLED"]]]]) }
            if path.hasSuffix("v1/profiles") {
                return method == "GET" ? MockHTTP.json(200, ["data": []])
                    : MockHTTP.json(201, ["data": ["id": "P1", "attributes": ["name": "n", "profileContent": profileData.base64EncodedString()]]])
            }
            return MockHTTP.json(200, ["data": []])
        }
        let (m, idStore) = try makeModel(client: ASCClient(http: mock, signJWT: { _ in "T" }))
        let acc = AppleAccount(displayName: "A", keyID: "K", issuerID: "I")
        try m.store.add(acc); try m.secrets.save("PEM", for: acc.id); m.reload(); m.selectedID = acc.id
        try idStore.save(SigningIdentity(privateKeyDER: Data([1]), certificateDER: Data([2]), ascCertificateId: "CERT1"), for: acc.id)
        m.readBundleID = { _ in "com.demo.app" }
        m.revealInFinder = { _ in }
        m.selectedIPA = URL(fileURLWithPath: "/tmp/demo.ipa")
        m.selectedPlugin = URL(fileURLWithPath: "/tmp/FakeGPS.dylib")

        let sentinel = URL(fileURLWithPath: "/tmp/inject-xyz/injected.ipa")
        var injectInput: (URL, URL)?
        m.performInjection = { ipa, plugin in injectInput = (ipa, plugin); return sentinel }
        var signedInput: URL?
        m.performResign = { ipa, out, _, _ in signedInput = ipa; _ = out }

        await m.resign()

        XCTAssertNil(m.banner, "不应有错误：\(m.banner ?? "")")
        XCTAssertEqual(injectInput?.0, URL(fileURLWithPath: "/tmp/demo.ipa"))
        XCTAssertEqual(injectInput?.1, URL(fileURLWithPath: "/tmp/FakeGPS.dylib"))
        XCTAssertEqual(signedInput, sentinel, "选了插件应把注入产物交给签名")
        // 输出命名 -injected.ipa（源目录 /tmp 可写）
        XCTAssertEqual(ReSignModel.resolveOutputURL(for: m.selectedIPA!, injected: true),
                       URL(fileURLWithPath: "/tmp/demo-injected.ipa"))
    }

    /// defaultPerformInjection 端到端：合成 arm64 app + 插件 → 产出的临时 IPA 内主程序含注入的 LC_LOAD_DYLIB
    func testDefaultPerformInjectionEmbedsLoadCommand() throws {
        for t in ["/usr/bin/clang", "/usr/bin/otool", "/usr/bin/ditto"] {
            guard FileManager.default.isExecutableFile(atPath: t) else { throw XCTSkip("no \(t)") }
        }
        guard (try? BundledInjectTools.insertDylib) != nil else { throw XCTSkip("缺内置 insert_dylib") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 合成最小 IPA：Payload/Demo.app（arm64 主程序）
        let app = dir.appendingPathComponent("Payload/Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let main = app.appendingPathComponent("Demo")
        try Subprocess.runChecked("/usr/bin/clang", ["-arch", "arm64", "-o", main.path, "-x", "c", "-"],
            input: Data("int main(){return 0;}".utf8))
        try (["CFBundleIdentifier": "com.demo.app", "CFBundleExecutable": "Demo"] as NSDictionary)
            .write(to: app.appendingPathComponent("Info.plist"))
        let ipa = dir.appendingPathComponent("demo.ipa")
        try Subprocess.runChecked("/usr/bin/ditto",
            ["-c", "-k", "--sequesterRsrc", "--keepParent", dir.appendingPathComponent("Payload").path, ipa.path])
        // 合成插件 dylib
        let plugin = dir.appendingPathComponent("Plug.dylib")
        try Subprocess.runChecked("/usr/bin/clang", ["-arch", "arm64", "-dynamiclib", "-o", plugin.path, "-x", "c", "-"],
            input: Data("int plug(){return 1;}".utf8))

        let injected = try ReSignModel.defaultPerformInjection(ipaURL: ipa, plugin: plugin)
        defer { try? FileManager.default.removeItem(at: injected.deletingLastPathComponent()) }
        // 解包产物 → 主程序依赖应含注入的 dylib
        let out = dir.appendingPathComponent("out")
        try Subprocess.runChecked("/usr/bin/ditto", ["-x", "-k", injected.path, out.path])
        let outApp = try XCTUnwrap(IPAResigner.findPayloadApp(in: out))
        let deps = try MachOInspect.dylibDependencies(outApp.appendingPathComponent("Demo"))
        XCTAssertTrue(deps.contains { $0.contains("Plug.dylib") }, "主程序应加载注入的 dylib，实际：\(deps)")
    }

    /// 未选插件 → performInjection 不被调用，performResign 收到的是原 IPA（回归保护）
    func testResignSkipsInjectionWhenNoPlugin() async throws {
        let profileData = Data([0xAB])
        let mock = MockHTTP { method, path in
            if path.hasSuffix("v1/bundleIds") {
                return method == "GET" ? MockHTTP.json(200, ["data": []])
                    : MockHTTP.json(201, ["data": ["id": "B1", "attributes": ["identifier": "com.demo.app", "name": "com.demo.app"]]])
            }
            if path.hasSuffix("v1/devices") { return MockHTTP.json(200, ["data": [["id": "D1", "attributes": ["udid": "u1", "name": "d1", "status": "ENABLED"]]]]) }
            if path.hasSuffix("v1/profiles") {
                return method == "GET" ? MockHTTP.json(200, ["data": []])
                    : MockHTTP.json(201, ["data": ["id": "P1", "attributes": ["name": "n", "profileContent": profileData.base64EncodedString()]]])
            }
            return MockHTTP.json(200, ["data": []])
        }
        let (m, idStore) = try makeModel(client: ASCClient(http: mock, signJWT: { _ in "T" }))
        let acc = AppleAccount(displayName: "A", keyID: "K", issuerID: "I")
        try m.store.add(acc); try m.secrets.save("PEM", for: acc.id); m.reload(); m.selectedID = acc.id
        try idStore.save(SigningIdentity(privateKeyDER: Data([1]), certificateDER: Data([2]), ascCertificateId: "CERT1"), for: acc.id)
        m.readBundleID = { _ in "com.demo.app" }
        m.revealInFinder = { _ in }
        m.selectedIPA = URL(fileURLWithPath: "/tmp/demo.ipa")
        m.selectedPlugin = nil

        var injectCalled = false
        m.performInjection = { _, _ in injectCalled = true; return URL(fileURLWithPath: "/tmp/none") }
        var signedInput: URL?
        m.performResign = { ipa, _, _, _ in signedInput = ipa }

        await m.resign()

        XCTAssertNil(m.banner, "不应有错误：\(m.banner ?? "")")
        XCTAssertFalse(injectCalled, "未选插件不应调用注入")
        XCTAssertEqual(signedInput, URL(fileURLWithPath: "/tmp/demo.ipa"), "未选插件应直接签原 IPA")
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter ReSignModelTests`
Expected: 编译失败（`selectedPlugin` / `performInjection` / `resolveOutputURL(injected:)` 未定义）。

- [ ] **Step 3: 加状态 + 注入闭包 + `defaultPerformInjection`**

在 `Sources/ReSignAppCore/ReSignModel.swift` 的属性区（`selectedIPA` 附近，约 22 行后）加：
```swift
    public var selectedPlugin: URL?
    public var performInjection: (_ ipaURL: URL, _ plugin: URL) throws -> URL
        = ReSignModel.defaultPerformInjection
```
在 `defaultPerformResign` 静态方法附近加：
```swift
    /// 默认注入：解包 IPA → 定位 app → xattr -cr → preflight（已解密/arm64）→ inject（内置 insert_dylib + ElleKit）
    /// → 重打包为临时 IPA，返回其 URL。失败时清掉自己的临时目录。
    public static func defaultPerformInjection(ipaURL: URL, plugin: URL) throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("inject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            try Subprocess.runChecked("/usr/bin/ditto", ["-x", "-k", ipaURL.path, work.path])
            guard let app = IPAResigner.findPayloadApp(in: work) else { throw ReSignAppError.msg("IPA 内找不到 Payload/*.app") }
            _ = try? Subprocess.run("/usr/bin/xattr", ["-cr", app.path])
            let target = try DylibInjector.preflight(appDir: app)
            try DylibInjector.inject(plugin: plugin, into: target,
                                     insertDylibTool: try BundledInjectTools.insertDylib,
                                     substrateReplacement: try BundledInjectTools.ellekit)
            let injectedIPA = work.appendingPathComponent("injected.ipa")
            try Subprocess.runChecked("/usr/bin/ditto",
                ["-c", "-k", "--sequesterRsrc", "--keepParent", work.appendingPathComponent("Payload").path, injectedIPA.path])
            return injectedIPA
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }
```

- [ ] **Step 4: `resolveOutputURL` 加 `injected` 参数**

把 `resolveOutputURL` 签名与首行改为（其余不变）：
```swift
    public static func resolveOutputURL(
        for source: URL,
        injected: Bool = false,
        isDirWritable: (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) },
        downloadsDir: () -> URL = {
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        }
    ) -> URL {
        let name = source.deletingPathExtension().lastPathComponent + (injected ? "-injected.ipa" : "-resigned.ipa")
        let srcDir = source.deletingLastPathComponent()
        if isDirWritable(srcDir.path) { return srcDir.appendingPathComponent(name) }
        return downloadsDir().appendingPathComponent(name)
    }
```

- [ ] **Step 5: `resign()` 加注入分支**

把 `resign()` 里从 `let output = ReSignModel.resolveOutputURL(for: ipa)` 到 `}.value` 这段替换为：
```swift
            let output = ReSignModel.resolveOutputURL(for: ipa, injected: selectedPlugin != nil)
            if output.deletingLastPathComponent() != ipa.deletingLastPathComponent() {
                log.append("源目录只读，已改输出到下载文件夹")
            }
            if let plugin = selectedPlugin { log.append("注入 \(plugin.lastPathComponent)…") }
            log.append("重签中…")
            let work = performResign
            let inject = performInjection
            let plugin = selectedPlugin
            let mobileprovisionData = built.profileData
            try await Task.detached {
                let toSign = try plugin.map { try inject(ipa, $0) } ?? ipa
                defer { if plugin != nil { try? FileManager.default.removeItem(at: toSign.deletingLastPathComponent()) } }
                try work(toSign, output, sid, mobileprovisionData)
            }.value
```
（其余 `log.append("✅ 完成…")` / `revealInFinder` / `catch` 不变。注入的重活与签名同在 `Task.detached` 内，避免主线程卡顿；注入产物用后即删。）

- [ ] **Step 6: 跑测试确认通过 + 全量回归**

Run: `swift test --filter ReSignModelTests` 然后 `swift test`
Expected: 三个新测试（注入编排 + `defaultPerformInjection` 合成端到端 + 未选插件回归）+ 现有 `testResignPipelineOrderAndDeviceIds`（未选插件路径，输出仍 `-resigned.ipa`）等全绿。

- [ ] **Step 7: 提交**

```bash
git add Sources/ReSignAppCore/ReSignModel.swift Tests/ReSignAppCoreTests/ReSignModelTests.swift
git commit -m "feat(resignappcore): optional plugin injection in resign() (defaultPerformInjection + selectedPlugin; -injected.ipa naming; no-plugin path unchanged)"
```

---

### Task 3: UI 插件选择行

**Files:**
- Modify: `Sources/ReSignApp/ReSignRootView.swift`

**Interfaces:**
- Consumes: `ReSignModel.selectedPlugin`（Task 2）、现有 `@Bindable model`、`NSOpenPanel`、`dropDestination`。
- Produces: IPA 行下方的「插件（dylib，可选）」选择/清除 UI；一键按钮文案随 `selectedPlugin` 变。

> SwiftUI 视图无单元测试（沿用本项目既有做法：UI 由 `swift build` 编译 + 启动冒烟验证，行为逻辑已由 Task 2 的模型测试覆盖）。

- [ ] **Step 1: 加插件选择 section**

在 `ReSignRootView.swift` 的 `ipaSection` 之后加一个新 `pluginSection`，并在 `body` 里把它插到 `ipaSection` 与 `resignSection` 之间。

在 `body` 中，把
```swift
            ipaSection
            resignSection
```
改为
```swift
            ipaSection
            pluginSection
            resignSection
```
在 `ipaSection` 计算属性之后加：
```swift
    @ViewBuilder private var pluginSection: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("插件（dylib，可选）").font(.subheadline)
                Spacer()
                if model.selectedPlugin != nil {
                    Button("清除") { model.selectedPlugin = nil }
                }
                Button("选择插件…") { pickPlugin() }
            }
            RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .frame(height: 44).foregroundStyle(.secondary.opacity(0.5))
                .overlay(Text(model.selectedPlugin?.lastPathComponent ?? "选一个 .dylib 注入（不选则只重签）")
                    .foregroundStyle(.secondary))
                .dropDestination(for: URL.self) { urls, _ in
                    guard let u = urls.first(where: { $0.pathExtension.lowercased() == "dylib" }) else { return false }
                    model.selectedPlugin = u; return true
                }
        }
    }
```
在「MARK: - 面板」区、`pickIPA()` 之后加：
```swift
    private func pickPlugin() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        if let dylib = UTType(filenameExtension: "dylib") { panel.allowedContentTypes = [dylib] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.selectedPlugin = url
    }
```

- [ ] **Step 2: 一键按钮文案随插件变**

在 `resignSection` 中，把
```swift
                    Label("一键重签", systemImage: "signature").frame(maxWidth: .infinity)
```
改为
```swift
                    Label(model.selectedPlugin == nil ? "一键重签" : "注入并重签",
                          systemImage: model.selectedPlugin == nil ? "signature" : "syringe")
                        .frame(maxWidth: .infinity)
```

- [ ] **Step 3: 编译 + 启动冒烟**

Run:
```bash
swift build --product ReSignApp
swift test
```
Expected: `ReSignApp` 编译无错；`swift test` 全绿（无回归）。UI 行为（选插件→按钮变「注入并重签」、拖 dylib 命中、清除置 nil）由实现者本地启动 app 目视确认；无 Aqua 会话时至少确认进程能起、无崩溃（沿用 plan 4 冒烟做法）。

- [ ] **Step 4: 提交**

```bash
git add Sources/ReSignApp/ReSignRootView.swift
git commit -m "feat(resignapp): optional plugin (dylib) row in one-tap flow; button toggles 一键重签/注入并重签"
```

---

## Self-Review

**Spec coverage：**
- 模型注入接缝（`selectedPlugin` + `performInjection` + `defaultPerformInjection` + `resign()` 分支）→ Task 2 ✓
- `defaultPerformInjection` 合成 arm64 端到端测试 → Task 2 Step 1 `testDefaultPerformInjectionEmbedsLoadCommand` ✓
- 输出命名 `-injected.ipa`/未选不变 → Task 2（`resolveOutputURL(injected:)` + 测试）✓
- 注入重活离主线程 → Task 2 `resign()`（`Task.detached` 内注入+签名）✓
- UI 可选插件行 + 按钮文案 → Task 3 ✓
- 内置工具打包 + 运行时定位（`BundledInjectTools` 双路径）→ Task 1 ✓
- 过公证的 Mach-O 各自签名 → Task 1 `package-resign.sh` ✓
- 受影响测试改定位（`InjectionPoCTests`→`BundledInjectTools`；`DylibInjectorTests` 不动）→ Task 1 Step 5 ✓
- 硬约束失败中文 banner → Task 2 经 `UserFacingMessage.from`/现有 `catch`（`InjectError`/`ReSignAppError` 落 banner）✓
- 明确不做（多插件/.deb/开关/畸形包/元数据）→ 未纳入 ✓

**Placeholder scan：** 每步含完整代码/命令。UI 无单测按项目既有做法（build+冒烟），已注明。无 TBD/TODO。

**Type consistency：** `BundledInjectTools.insertDylib/ellekit`（Task 1）被 Task 2 `defaultPerformInjection` 消费；`performInjection: (URL, URL) throws -> URL`、`selectedPlugin: URL?`、`resolveOutputURL(for:injected:...)`、`defaultPerformInjection(ipaURL:plugin:)` 跨 Task 2/3 一致；`ReSignAppError.msg`、`DylibInjector.preflight/inject`、`IPAResigner.findPayloadApp`、`Subprocess.runChecked/run`、`MachOInspect.archs` 均与现有源一致。测试用 `makeModel`/`MockHTTP`/`InMemorySigningIdentityStore`（现有）。
