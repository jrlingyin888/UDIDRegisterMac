# 注入式重签（C 方案）计划 1：注入核心 + PoC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建成可独立测试的 dylib 注入核心（`DylibInjector`）+ 内置 `insert_dylib`/`ElleKit`，并用真机 PoC 验证「注入 + ElleKit + 通配签名 + 免越狱装机 hook 生效」这条链路成立。

**Architecture:** 在 ReSignKit 新增 `MachOInspect`（读 cryptid/架构/依赖）+ `DylibInjector`（拷 dylib 进 Frameworks、改依赖指向 ElleKit、用 insert_dylib 插 LC_LOAD_DYLIB）。内置工具放 `Resources/inject/`。核心用**合成的 arm64 二进制**做确定性单测；整链路成立性由**真机 PoC**（需用户材料）验证。

**Tech Stack:** Swift 5.9 / SwiftPM / macOS 14；`otool`、`install_name_tool`、`clang`（测试造二进制）、`codesign`、`ditto`（子进程）；`insert_dylib`（内置，源码构建）、`ElleKit.dylib`（内置，预编译）。

## Global Constraints

- 平台 `macOS(.v14)`，`swift-tools-version: 5.9`。保持 `swift test` 全绿（当前基线含前序工作，见 `.superpowers/sdd/progress.md`）。
- **输入 IPA 必须已解密**：主可执行 `LC_ENCRYPTION_INFO(_64).cryptid == 0`（或无该 load command）；否则 `InjectError.encrypted`。
- **仅 arm64**：注入的 dylib 与目标主程序须为 arm64。
- **只往干净 app 注入**：不重签别人已注入的 app（其注入二进制签名报 `internal error in Code Signing subsystem`）。
- 注入位置统一 `Payload/<App>.app/Frameworks/`。插件对 substrate 的依赖用 `install_name_tool -change` 指向自带 ElleKit。
- 新增用户可见文案用中文。**本计划到 PoC 门槛为止**；PoC 通过后另写 Phase C 计划（接入 resign/UI/打包）。
- 内置件来源与版本记录在 `Resources/inject/README`。

## 文件结构

- 加 `Resources/inject/insert_dylib`（源码构建的可执行）、`Resources/inject/ElleKit.dylib`（预编译）、`Resources/inject/README`。
- 加 `Sources/ReSignKit/MachOInspect.swift`：Mach-O 读取（cryptid/arch/dylib 依赖），纯解析 + otool 包装。
- 加 `Sources/ReSignKit/DylibInjector.swift`：`InjectableApp`、`InjectError`、`preflight`、`inject`。
- 测试 `Tests/ReSignKitTests/MachOInspectTests.swift`、`Tests/ReSignKitTests/DylibInjectorTests.swift`（合成二进制）。
- PoC：`Tests/ReSignKitTests/InjectionPoCTests.swift`（gated，需真机材料）。

---

### Task 1: 内置 insert_dylib + ElleKit

**Files:**
- Create: `Resources/inject/insert_dylib`, `Resources/inject/ElleKit.dylib`, `Resources/inject/README`
- Modify: `.gitignore`（确保这两个二进制被跟踪提交）

**Interfaces:**
- Produces: 仓库内可用的 `Resources/inject/insert_dylib`（可执行）与 `Resources/inject/ElleKit.dylib`（arm64 dylib），供 Task 3 及后续。

> 需联网构建/下载。若执行环境无网络，此任务须由人（用户/控制者）提供这两个文件后再继续——报 BLOCKED 并说明。

- [ ] **Step 1: 构建 insert_dylib**

```bash
mkdir -p Resources/inject
cd /tmp && rm -rf insert_dylib && git clone https://github.com/tyilo/insert_dylib.git
cd insert_dylib && xcodebuild -project insert_dylib.xcodeproj -configuration Release SYMROOT=build 2>&1 | tail -3
cp build/Release/insert_dylib "$OLDPWD/Resources/inject/insert_dylib" 2>/dev/null \
  || cp "$(find build -name insert_dylib -type f | head -1)" "$OLDPWD/Resources/inject/insert_dylib"
cd "$OLDPWD"; chmod +x Resources/inject/insert_dylib
```

- [ ] **Step 2: 取 ElleKit 预编译 dylib**

从 ElleKit 开源发布（https://github.com/evelyneee/ellekit）取预编译的 `libellekit.dylib`（arm64），存为 `Resources/inject/ElleKit.dylib`。若只有源码则按其 README 构建 arm64 dylib。

- [ ] **Step 3: 校验两个二进制**

Run:
```bash
file Resources/inject/insert_dylib Resources/inject/ElleKit.dylib
Resources/inject/insert_dylib 2>&1 | head -2   # 打印用法
lipo -archs Resources/inject/ElleKit.dylib
```
Expected: `insert_dylib` 是可执行 Mach-O 并打印用法；`ElleKit.dylib` 含 `arm64`。

- [ ] **Step 4: 写来源说明**

`Resources/inject/README`：记录两者的 repo、commit/tag、构建命令、许可证。

- [ ] **Step 5: 提交**

```bash
git add -f Resources/inject/insert_dylib Resources/inject/ElleKit.dylib Resources/inject/README
git commit -m "build(inject): bundle insert_dylib (built) + ElleKit runtime for dylib injection"
```

---

### Task 2: `MachOInspect` — cryptid / 架构 / dylib 依赖

**Files:**
- Create: `Sources/ReSignKit/MachOInspect.swift`
- Test: `Tests/ReSignKitTests/MachOInspectTests.swift`

**Interfaces:**
- Consumes: `Subprocess.run`（现有）。
- Produces:
  - `static func cryptidIsEncrypted(otoolLoadCommands: String) -> Bool`（纯解析）
  - `static func loadDylibs(otoolLoadCommands: String) -> [String]`（纯解析）
  - `static func isEncrypted(_ macho: URL) throws -> Bool`、`static func archs(_ macho: URL) throws -> [String]`、`static func dylibDependencies(_ macho: URL) throws -> [String]`（跑 otool/lipo 的包装）

- [ ] **Step 1: 写纯解析的失败测试**

```swift
import XCTest
@testable import ReSignKit

final class MachOInspectTests: XCTestCase {
    func testCryptidParsingDetectsEncrypted() {
        let enc = """
                  cmd LC_ENCRYPTION_INFO_64
              cmdsize 24
             cryptoff 16384
            cryptsize 32768
               cryptid 1
        """
        let dec = enc.replacingOccurrences(of: "cryptid 1", with: "cryptid 0")
        XCTAssertTrue(MachOInspect.cryptidIsEncrypted(otoolLoadCommands: enc))
        XCTAssertFalse(MachOInspect.cryptidIsEncrypted(otoolLoadCommands: dec))
        XCTAssertFalse(MachOInspect.cryptidIsEncrypted(otoolLoadCommands: "（无加密段）"))
    }
    func testLoadDylibsParsing() {
        let s = """
                  cmd LC_LOAD_DYLIB
                 name @rpath/CydiaSubstrate (offset 24)
                  cmd LC_LOAD_DYLIB
                 name /usr/lib/libSystem.B.dylib (offset 24)
        """
        XCTAssertEqual(MachOInspect.loadDylibs(otoolLoadCommands: s),
                       ["@rpath/CydiaSubstrate", "/usr/lib/libSystem.B.dylib"])
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter MachOInspectTests`
Expected: 编译失败（`MachOInspect` 未定义）。

- [ ] **Step 3: 实现 `MachOInspect`**

```swift
import Foundation

/// 读 Mach-O 关键信息：是否 FairPlay 加密、CPU 架构、LC_LOAD_DYLIB 依赖。
public enum MachOInspect {
    /// 从 `otool -l` 文本判断是否仍加密：存在 LC_ENCRYPTION_INFO(_64) 且 cryptid != 0。
    public static func cryptidIsEncrypted(otoolLoadCommands s: String) -> Bool {
        guard s.contains("LC_ENCRYPTION_INFO") else { return false }
        for line in s.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("cryptid") {
                let v = t.dropFirst("cryptid".count).trimmingCharacters(in: .whitespaces)
                if v != "0" { return true }
            }
        }
        return false
    }
    /// 从 `otool -l` 文本抽取 LC_LOAD_DYLIB 的 name（去掉 " (offset N)" 尾巴）。
    public static func loadDylibs(otoolLoadCommands s: String) -> [String] {
        var out: [String] = []; var lines = ArraySlice(s.split(separator: "\n", omittingEmptySubsequences: false))
        while let line = lines.first {
            lines = lines.dropFirst()
            if line.trimmingCharacters(in: .whitespaces) == "cmd LC_LOAD_DYLIB" {
                if let nameLine = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("name ") }) {
                    var n = nameLine.trimmingCharacters(in: .whitespaces).dropFirst("name ".count)
                    if let r = n.range(of: " (offset ") { n = n[..<r.lowerBound] }
                    out.append(String(n))
                }
            }
        }
        return out
    }

    public static func isEncrypted(_ macho: URL) throws -> Bool {
        let r = try Subprocess.runChecked("/usr/bin/otool", ["-l", macho.path])
        return cryptidIsEncrypted(otoolLoadCommands: r.stdout)
    }
    public static func archs(_ macho: URL) throws -> [String] {
        let r = try Subprocess.runChecked("/usr/bin/lipo", ["-archs", macho.path])
        return r.stdout.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init).filter { !$0.isEmpty }
    }
    public static func dylibDependencies(_ macho: URL) throws -> [String] {
        let r = try Subprocess.runChecked("/usr/bin/otool", ["-l", macho.path])
        return loadDylibs(otoolLoadCommands: r.stdout)
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter MachOInspectTests`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add Sources/ReSignKit/MachOInspect.swift Tests/ReSignKitTests/MachOInspectTests.swift
git commit -m "feat(resignkit): MachOInspect — cryptid/arch/dylib-deps via otool (pure parsers tested)"
```

---

### Task 3: `DylibInjector` — preflight + inject（合成二进制端到端）

**Files:**
- Create: `Sources/ReSignKit/DylibInjector.swift`
- Test: `Tests/ReSignKitTests/DylibInjectorTests.swift`

**Interfaces:**
- Consumes: `MachOInspect`（Task 2）、`Resources/inject/insert_dylib`（Task 1）、`Subprocess`、`install_name_tool`、`otool`。
- Produces:
  - `struct InjectableApp { let appDir: URL; let mainExecutable: URL }`
  - `enum InjectError: Error, Equatable { case notApp, encrypted, badArch(String), notMachO(String), insertFailed(String) }`
  - `struct DylibInjector { static func preflight(appDir: URL) throws -> InjectableApp; static func inject(plugin: URL, into: InjectableApp, insertDylibTool: URL, substrateReplacement: URL?) throws }`

> `insertDylibTool` 与 `substrateReplacement`（ElleKit）作参数注入，测试可传仓库内 `Resources/inject/…`；生产由上层从 app bundle 内的资源路径传入。

- [ ] **Step 1: 写合成二进制的失败测试**

```swift
import XCTest
@testable import ReSignKit

final class DylibInjectorTests: XCTestCase {
    // 用 clang 造 arm64 主程序 + 插件 dylib，拼一个最小 .app
    func makeSyntheticApp(in dir: URL) throws -> URL {
        let app = dir.appendingPathComponent("Payload/Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let main = app.appendingPathComponent("Demo")
        try Subprocess.runChecked("/usr/bin/clang", ["-arch", "arm64", "-o", main.path, "-x", "c", "-"],
            input: Data("int main(){return 0;}".utf8))
        let info = app.appendingPathComponent("Info.plist")
        try "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleExecutable</key><string>Demo</string></dict></plist>".write(to: info, atomically: true, encoding: .utf8)
        return app
    }
    func makePluginDylib(at url: URL) throws {
        try Subprocess.runChecked("/usr/bin/clang", ["-arch", "arm64", "-dynamiclib", "-o", url.path, "-x", "c", "-"],
            input: Data("int plugin_init(){return 1;}".utf8))
    }

    func testInjectAddsLoadCommandAndCopiesDylib() throws {
        for t in ["/usr/bin/clang", "/usr/bin/otool"] { guard FileManager.default.isExecutableFile(atPath: t) else { throw XCTSkip("no \(t)") } }
        let insertTool = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/inject/insert_dylib")
        guard FileManager.default.isExecutableFile(atPath: insertTool.path) else { throw XCTSkip("no bundled insert_dylib（Task 1 先做）") }
        let dir = try TestTemp.dir(); defer { try? FileManager.default.removeItem(at: dir) }
        let app = try makeSyntheticApp(in: dir)
        let plugin = dir.appendingPathComponent("FakeGPS.dylib"); try makePluginDylib(at: plugin)

        let target = try DylibInjector.preflight(appDir: app)   // 干净 clang 二进制 → 不加密、arm64
        try DylibInjector.inject(plugin: plugin, into: target, insertDylibTool: insertTool, substrateReplacement: nil)

        // 断言：dylib 已拷进 Frameworks/
        let embedded = app.appendingPathComponent("Frameworks/FakeGPS.dylib")
        XCTAssertTrue(FileManager.default.fileExists(atPath: embedded.path))
        // 断言：主程序多了指向该 dylib 的 LC_LOAD_DYLIB
        let deps = try MachOInspect.dylibDependencies(target.mainExecutable)
        XCTAssertTrue(deps.contains { $0.contains("FakeGPS.dylib") }, "主程序应加载注入的 dylib，实际依赖：\(deps)")
    }

    func testPreflightRejectsMissingApp() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try DylibInjector.preflight(appDir: dir)) { XCTAssertEqual($0 as? InjectError, .notApp) }
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter DylibInjectorTests`
Expected: 编译失败（`DylibInjector` 未定义）。

- [ ] **Step 3: 实现 `DylibInjector`**

```swift
import Foundation

public struct InjectableApp { public let appDir: URL; public let mainExecutable: URL }

public enum InjectError: Error, Equatable {
    case notApp, encrypted, badArch(String), notMachO(String), insertFailed(String)
}

public struct DylibInjector {
    /// 定位主程序（Info.plist 的 CFBundleExecutable），校验存在、arm64、未加密。
    public static func preflight(appDir: URL) throws -> InjectableApp {
        let info = appDir.appendingPathComponent("Info.plist")
        guard let d = NSDictionary(contentsOf: info),
              let exe = d["CFBundleExecutable"] as? String else { throw InjectError.notApp }
        let main = appDir.appendingPathComponent(exe)
        guard FileManager.default.isExecutableFile(atPath: main.path) else { throw InjectError.notApp }
        let archs = (try? MachOInspect.archs(main)) ?? []
        guard !archs.isEmpty else { throw InjectError.notMachO(exe) }
        guard archs.contains("arm64") else { throw InjectError.badArch(archs.joined(separator: ",")) }
        if (try? MachOInspect.isEncrypted(main)) == true { throw InjectError.encrypted }
        return InjectableApp(appDir: appDir, mainExecutable: main)
    }

    /// 注入一个插件 dylib：拷进 Frameworks/、（若依赖 substrate 且给了替换）改依赖指向 ElleKit、insert_dylib 插 LC_LOAD_DYLIB。
    public static func inject(plugin: URL, into app: InjectableApp,
                             insertDylibTool: URL, substrateReplacement: URL?) throws {
        let pArchs = (try? MachOInspect.archs(plugin)) ?? []
        guard pArchs.contains("arm64") else { throw InjectError.badArch("plugin: \(pArchs.joined(separator: ","))") }

        let fw = app.appDir.appendingPathComponent("Frameworks")
        try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
        let dest = fw.appendingPathComponent(plugin.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: plugin, to: dest)

        // 若插件依赖 CydiaSubstrate/libsubstrate 且提供了 ElleKit → 改依赖指向自带 ElleKit
        if let ellekit = substrateReplacement {
            let ekDest = fw.appendingPathComponent("ElleKit.dylib")
            if !FileManager.default.fileExists(atPath: ekDest.path) { try FileManager.default.copyItem(at: ellekit, to: ekDest) }
            let deps = (try? MachOInspect.dylibDependencies(dest)) ?? []
            for dep in deps where dep.contains("CydiaSubstrate") || dep.contains("libsubstrate") {
                _ = try? Subprocess.runChecked("/usr/bin/install_name_tool",
                    ["-change", dep, "@executable_path/Frameworks/ElleKit.dylib", dest.path])
            }
        }

        // 给主程序插 LC_LOAD_DYLIB → @executable_path/Frameworks/<plugin>
        let loadPath = "@executable_path/Frameworks/\(plugin.lastPathComponent)"
        let r = try Subprocess.run(insertDylibTool.path,
            ["--inplace", "--all-yes", loadPath, app.mainExecutable.path])
        guard r.status == 0 else { throw InjectError.insertFailed(r.stderr) }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter DylibInjectorTests`
Expected: PASS（合成 app 注入后，Frameworks/ 有 dylib、主程序依赖含它）。

- [ ] **Step 5: 全量回归 + 提交**

Run: `swift test`
Expected: 全绿。
```bash
git add Sources/ReSignKit/DylibInjector.swift Tests/ReSignKitTests/DylibInjectorTests.swift
git commit -m "feat(resignkit): DylibInjector — preflight (decrypted/arm64) + inject (embed+relink+insert_dylib), synthetic-binary tested"
```

---

### Task 4: 真机 PoC 门槛（需用户材料）

**Files:**
- Create: `Tests/ReSignKitTests/InjectionPoCTests.swift`（gated，`POC=1` 才跑）
- 产出：`.superpowers/sdd/injection-poc-result.md`（PoC 结论，gitignored）

**Interfaces:** 无新对外接口；串起 Task 1–3 + 现有通配签名，端到端验证。

> **BLOCKED until 用户提供：** 干净（未注入）已解密 IPA、具体插件 dylib（如 FakeGPS）、测试设备。

- [ ] **Step 1: 写 gated PoC 测试**

`InjectionPoCTests.swift`：`POC=1` 且给了 `POC_IPA`/`POC_PLUGIN` 环境变量才跑。解包 IPA → `xattr -cr` → `DylibInjector.preflight` → `inject(plugin, substrateReplacement: Resources/inject/ElleKit.dylib)` → 用**通配描述文件**（复用 `ReSignModel` 已验证的通配流程导出的 profile）+ `TemporaryKeychainIdentity` 通配签名 → 产出 `~/Downloads/<name>-injected.ipa`。断言产物存在、`codesign --verify --deep --strict` 通过、no prompt、登录钥匙串干净。

- [ ] **Step 2: 跑 PoC（用户材料到位后）**

Run: `POC=1 POC_IPA=<干净解密IPA> POC_PLUGIN=<插件dylib> swift test --filter InjectionPoCTests`
Expected: 产出 injected IPA，验签通过。

- [ ] **Step 3: 真机装机验证（人工）**

把 injected IPA 用 Apple Configurator 装到测试设备 → 启动 app → 确认插件 hook 生效（如 FakeGPS 真的改了定位）。

- [ ] **Step 4: 记录 PoC 结论**

写 `.superpowers/sdd/injection-poc-result.md`：通过/不通过、现象、若不通过的具体报错（用于调整 ElleKit 版本 / 注入顺序 / 加载方式）。

- [ ] **Step 5: 决策门槛**

- **PoC 通过** → 另写 Phase C 计划（`DylibInjector` 接入 `ReSignModel.resign()` 的注入分支 + 插件选择 UI + 打包内置 insert_dylib/ElleKit + 真机验收）。
- **PoC 不通过** → 回到 systematic-debugging，据现象定位（多半在 ElleKit 加载/兼容或注入顺序），调整后重试；必要时回 brainstorm 改方案。

---

## Self-Review

**Spec coverage：**
- 硬约束（已解密/arm64/干净 app）→ Task 3 `preflight` + Task 2 `MachOInspect` ✓
- 架构流水线（xattr→注入→通配签名）→ Task 3（注入核心）+ Task 4（串通配签名，PoC）✓
- 内置 insert_dylib + ElleKit → Task 1 ✓
- 插件↔ElleKit 依赖改写 → Task 3 `inject`（install_name_tool -change）✓
- PoC 优先 → Task 4 明确为门槛,需用户材料 ✓
- 错误处理（encrypted/badArch/notMachO/insertFailed）→ `InjectError` + preflight/inject ✓
- 明确不做（.deb/framework/开关/解密/重签已注入 app）→ 本计划不涉及,Phase C 也不含 ✓

**Placeholder scan：** 每个代码步骤给出完整代码/命令。Task 1 依赖联网,已注明无网时报 BLOCKED 由人提供。Task 4 明确 BLOCKED on 用户材料。

**Type consistency：** `MachOInspect.{cryptidIsEncrypted,loadDylibs,isEncrypted,archs,dylibDependencies}`、`InjectableApp{appDir,mainExecutable}`、`InjectError{notApp,encrypted,badArch,notMachO,insertFailed}`、`DylibInjector.{preflight,inject(plugin:into:insertDylibTool:substrateReplacement:)}` 跨任务一致。测试用 `TestTemp.dir()`（现有 ReSignKitTests 辅助）与 `Subprocess`（现有）。
</content>
