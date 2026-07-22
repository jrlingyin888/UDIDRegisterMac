# 扩展感知的通配签名（Phase C1）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `AppResigner` 能用一张通配 Ad Hoc 描述文件签含 `*.appex` / Watch app 的真实 app（如带 2 个 appex 的 M3），并用真实 M3-5.0.0 注入 FakeGPS 端到端验收。

**Architecture:** 引擎已有由内向外签的机制（`AppBundle.codeToSignInsideOut()` 已收集 frameworks/dylibs + appex + watch + 主 app）。改动集中在 `AppResigner.resign`：删掉拒签嵌套 bundle 的 guard，改为把每个**可执行 bundle**（主 app / `*.appex` / `Watch/*.app`）都塞一份通配 `embedded.mobileprovision` + 带同一份通配 entitlements 签；**库**（framework/dylib）照旧不带。

**Tech Stack:** Swift 5.9 / SwiftPM / macOS 14；`codesign`、`ditto`、`security`、`openssl`（子进程）；内置 `insert_dylib` + `ElleKit.dylib`（已提交）。

## Global Constraints

- 平台 `macOS(.v14)`，`swift-tools-version: 5.9`。保持 `swift test` 全绿。
- **不改任何 bundle id**（通配 profile 通配所有 id，原 id 天然满足苹果「appex id = 主 app id.后缀」规则）。
- **不改注入逻辑**：FakeGPS + ElleKit 只进主 app 的 `Frameworks/`，扩展不注入。
- 所有可执行 bundle 用**同一份通配 profile 的 entitlements**（`application-identifier T46A6Q874U.*` / `team-identifier` / `keychain-access-groups T46A6Q874U.*` / `get-task-allow=false`）——与主 app 现有行为一致，扩展照做。
- app-group / 推送 / 深链 / wifi-info 一并丢弃（通配 ad-hoc 不授权，对改定位无影响）。
- 用户可见文案用中文。
- 输入 IPA 必须已解密（`cryptid==0`），仅 arm64，只往干净 app 注入。

## 文件结构

- 改 `Sources/ReSignKit/AppResigner.swift`：`resign(appDir:identity:profileData:entitlements:)` 去掉 `unsupportedNestedBundle` guard，签名循环按「可执行 bundle vs 库」分类处理。
- 改 `Tests/ReSignKitTests/AppResignerTests.swift`：把现有 `testResignRefusesAppWithNestedAppex`（断言旧拒签行为）替换为 `testResignSignsNestedAppex`（断言新扩展签名行为）。
- （验收）复用 `Tests/ReSignAppCoreTests/InjectionPoCTests.swift`（不带 `POC_STRIP_PLUGINS`）跑真实 M3。

---

### Task 1: `AppResigner` 支持签嵌套可执行 bundle（合成 appex 端到端）

**Files:**
- Modify: `Sources/ReSignKit/AppResigner.swift`
- Test: `Tests/ReSignKitTests/AppResignerTests.swift`

**Interfaces:**
- Consumes: `AppBundle.codeToSignInsideOut()`（现有，返回 `[URL]`，库/appex/watch 在前、主 app 最后）、`AppBundle.embeddedProfileURL()`（现有，返回 `<appDir>/embedded.mobileprovision`）、`CodesignInvocation.signArgs(identity:target:entitlements:)`、`CodesignInvocation.verifyArgs(target:)`、`Subprocess.run`、`TemporaryKeychainIdentity`。
- Produces: `AppResigner.resign(appDir:identity:profileData:entitlements:)` 行为变更——不再对含 appex/Watch 的 app 抛 `unsupportedNestedBundle`，而是给每个可执行 bundle 塞各自 `embedded.mobileprovision` + 带 entitlements 签。对外签名不变。`ReSignError.unsupportedNestedBundle` 枚举保留（不再由本方法触发）。

- [ ] **Step 1: 改测试——把「拒签」测试替换为「签上扩展」测试（先见红）**

在 `Tests/ReSignKitTests/AppResignerTests.swift` 中，**删除**整个 `testResignRefusesAppWithNestedAppex()` 方法（第 38–73 行，含其上方 `/// C1：...` 注释），**替换为**：

```swift
    /// C1：含 PlugIns/*.appex 的 app 现在应整体签名——每个 appex 也签上、各自带 embedded.mobileprovision
    /// 与通配 entitlements，而不是拒签。通配 profile 一张覆盖主 app + 所有扩展。
    func testResignSignsNestedAppex() throws {
        for tool in ["/usr/bin/codesign", "/usr/bin/openssl", "/usr/bin/security"] {
            guard FileManager.default.isExecutableFile(atPath: tool) else { throw XCTSkip("no \(tool)") }
        }
        let tmp = try TestTemp.dir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let app = tmp.appendingPathComponent("Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "com.demo.app", "CFBundleExecutable": "Demo"] as NSDictionary)
            .write(to: app.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"),
                                         to: app.appendingPathComponent("Demo"))
        // 合成扩展 bundle：PlugIns/Ext.appex（用真实 mach-o /bin/echo 作可执行）
        let appex = app.appendingPathComponent("PlugIns").appendingPathComponent("Ext.appex")
        try FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
        try (["CFBundleIdentifier": "com.demo.app.Ext", "CFBundleExecutable": "Ext"] as NSDictionary)
            .write(to: appex.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"),
                                         to: appex.appendingPathComponent("Ext"))

        let fx = try TestSigningFixture.make(in: tmp); defer { fx.cleanup() }
        let id = try TemporaryKeychainIdentity(privateKey: fx.privateKey,
                                               certificateDER: fx.certificateDER, commonName: fx.commonName)
        defer { id.cleanup() }
        try id.addToSearchListForCodesign()

        // 通配 entitlements（application-identifier 用通配 *，覆盖主 app + 扩展）
        let ent: [String: Any] = ["application-identifier": "TEAMID.*", "get-task-allow": false]
        try AppResigner.resign(appDir: app, identity: id,
                               profileData: Data("FAKE-PROFILE".utf8), entitlements: ent)

        // 主 app + 扩展各自都有 embedded.mobileprovision
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("embedded.mobileprovision").path),
                      "主 app 应有 embedded.mobileprovision")
        XCTAssertTrue(FileManager.default.fileExists(atPath: appex.appendingPathComponent("embedded.mobileprovision").path),
                      "扩展应有各自的 embedded.mobileprovision")
        // 整体 --deep --strict 验签通过（会递归校验 appex 签名）
        let v = try Subprocess.run("/usr/bin/codesign",
            CodesignInvocation.verifyArgs(target: app.path) + ["--keychain", id.keychainPath])
        XCTAssertEqual(v.status, 0, "含扩展的 app 应整体验签通过：\(v.stderr)")
        // 扩展本身也带上了 entitlements
        let d = try Subprocess.run("/usr/bin/codesign", ["-d", "--entitlements", ":-", appex.path])
        XCTAssertTrue(d.stdout.contains("TEAMID"), "扩展应带上 entitlements：\(d.stdout)")
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter AppResignerTests/testResignSignsNestedAppex`
Expected: FAIL——现有实现对含 appex 的 app 抛 `unsupportedNestedBundle`，`resign` throws，测试在 `try AppResigner.resign(...)` 处失败。

- [ ] **Step 3: 改实现——去掉 guard，按可执行 bundle / 库分类签名**

在 `Sources/ReSignKit/AppResigner.swift` 中，把 `resign(appDir:identity:profileData:entitlements:)` 方法体**整体替换**为：

```swift
    public static func resign(appDir: URL, identity: TemporaryKeychainIdentity,
                              profileData: Data, entitlements: [String: Any]) throws {
        let bundle = AppBundle(appDir: appDir)

        // entitlements 落临时 plist（所有可执行 bundle 共用同一份通配 entitlements）
        let entURL = FileManager.default.temporaryDirectory.appendingPathComponent("entitlements-\(UUID().uuidString).plist")
        let entData = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
        try entData.write(to: entURL)
        defer { try? FileManager.default.removeItem(at: entURL) }

        // 由内向外签名。可执行 bundle（主 app / *.appex / Watch/*.app）：塞各自 embedded.mobileprovision + 带
        // entitlements 签；库（*.framework / *.dylib）：不塞 profile、不带 entitlements。
        // 顺序由 codeToSignInsideOut 保证（库/appex/watch 在前，主 app 最后），故每个 appex 的描述文件+签名
        // 会被随后主 app 的签名封入。
        let targets = bundle.codeToSignInsideOut()
        for t in targets {
            let isExecBundle = (t == appDir) || t.pathExtension == "appex" || t.pathExtension == "app"
            if isExecBundle {
                try profileData.write(to: AppBundle(appDir: t).embeddedProfileURL())
            }
            let args = CodesignInvocation.signArgs(identity: identity.signingIdentity,
                        target: t.path, entitlements: isExecBundle ? entURL.path : nil)
                        + ["--keychain", identity.keychainPath]
            let r = try Subprocess.run("/usr/bin/codesign", args)
            guard r.status == 0 else { throw ReSignError.codesignFailed("\(t.lastPathComponent): \(r.stderr)") }
        }

        // 验签整棵嵌套签名树
        let v = try Subprocess.run("/usr/bin/codesign",
            CodesignInvocation.verifyArgs(target: appDir.path) + ["--keychain", identity.keychainPath])
        guard v.status == 0 else { throw ReSignError.codesignFailed("verify: \(v.stderr)") }
    }
```

> 说明：删掉了原来开头的 `bundle.nestedExecutableBundles()` guard 与 `throw ReSignError.unsupportedNestedBundle(...)`；`AppBundle.nestedExecutableBundles()` 与 `ReSignError.unsupportedNestedBundle` 均保留（前者供后续 UI/诊断，后者供未来确不支持的形态）。`AppBundle(appDir: t).embeddedProfileURL()` 对任意 bundle t 返回 `t/embedded.mobileprovision`，复用现有 helper。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter AppResignerTests`
Expected: PASS——`testResignSignsNestedAppex`（含扩展整体签+验签通过）、`testResignSyntheticAppVerifiesAndCarriesEntitlements`（主 app 单签，行为不变）、`testResignMobileprovisionDataDerivesEntitlementsFromProfile`（profile 派生 entitlements，不变）全绿。

- [ ] **Step 5: 全量回归**

Run: `swift test`
Expected: 全绿（gated LIVE/PoC 测试默认跳过）。

- [ ] **Step 6: 提交**

```bash
git add Sources/ReSignKit/AppResigner.swift Tests/ReSignKitTests/AppResignerTests.swift
git commit -m "feat(resignkit): AppResigner signs nested appex/Watch with one wildcard profile (drop reject guard; per-bundle embedded profile + entitlements)"
```

---

### Task 2: 真实 M3-5.0.0 注入 PoC（扩展签名端到端验收）

**Files:**
- 无代码改动（复用 `Tests/ReSignAppCoreTests/InjectionPoCTests.swift`，不带 `POC_STRIP_PLUGINS`）。
- 产出：`~/Downloads/移动办公M3-5.0.0-injected.ipa`（供用户装机）+ 更新 `.superpowers/sdd/injection-poc-result.md`（gitignored）。

**Interfaces:**
- Consumes: Task 1 的扩展签名能力；`DylibInjector`、`MachOInspect`（已完成）；真账号通配流程（`ASCClient` / `ReSignModel.defaultPerformResign`）；材料 `~/Downloads/test_resign_files/移动办公M3-5.0.0.ipa`（干净·已解密·2 appex）+ `FakeGPS.dylib`。
- Produces: 可装的注入版 M3 IPA；扩展被通配签名的实证。

> 需真账号（钥匙串取签名身份 + 联网建描述文件），跑时可能弹钥匙串授权框。M3-5.0.0 是标准 zip（`ditto -x -k` 可解）。

- [ ] **Step 1: 跑 PoC（不 strip 扩展，走新扩展签名路径）**

Run:
```bash
POC=1 \
  POC_IPA=~/Downloads/test_resign_files/移动办公M3-5.0.0.ipa \
  POC_PLUGIN=~/Downloads/test_resign_files/FakeGPS.dylib \
  swift test --filter InjectionPoCTests
```
Expected: PASS。日志含「通配 App ID SYBWQ53DXF，设备 N 台」「注入完成，主程序依赖含插件」「✅ 注入+重签产物: …移动办公M3-5.0.0-injected.ipa」「codesign --verify 退出码 0」。注意**不设** `POC_STRIP_PLUGINS`——本次要签上 2 个 appex。

- [ ] **Step 2: 核验产物结构（扩展确被通配签名）**

Run:
```bash
OUT=~/Downloads/移动办公M3-5.0.0-injected.ipa
W=$(mktemp -d); ditto -x -k "$OUT" "$W"
APP=$(find "$W/Payload" -maxdepth 1 -name "*.app" | head -1)
echo "主 app embedded:"; ls -la "$APP/embedded.mobileprovision"
echo "扩展 embedded:"; ls "$APP"/PlugIns/*.appex/embedded.mobileprovision
echo "主程序注入:"; otool -L "$APP/M3" | grep -i fakegps
echo "FakeGPS→ElleKit:"; otool -L "$APP/Frameworks/FakeGPS.dylib" | grep -i ellekit
for ax in "$APP"/PlugIns/*.appex; do
  echo "== $(basename "$ax") =="; codesign -dv "$ax" 2>&1 | grep -iE "Identifier|TeamIdentifier"
  codesign --verify --strict "$ax" 2>&1 && echo "  ✓ appex 验签通过"
done
codesign --verify --deep --strict "$APP" 2>&1 && echo "✓ 整体 --deep --strict 通过"
rm -rf "$W"
```
Expected: 主 app + 两个 appex 各有 `embedded.mobileprovision`；主程序含 `@executable_path/Frameworks/FakeGPS.dylib`；FakeGPS 依赖指向 ElleKit；两个 appex TeamIdentifier=`T46A6Q874U`、各自验签通过；整体 `--deep --strict` 通过。

- [ ] **Step 3: 记录结论**

追加 `.superpowers/sdd/injection-poc-result.md`：M3-5.0.0 扩展签名 PoC 通过/不通过、产物路径、两个 appex 是否签上、整体验签结果。

- [ ] **Step 4: 用户装机验收（人工，计划外）**

把 `~/Downloads/移动办公M3-5.0.0-injected.ipa` 装到 provisioned 设备 → 启动 M3 → 确认能进、扩展不致启动崩溃 → 打开考勤定位，确认 FakeGPS 改了定位。
- **通过** → Phase C1 完成，进 Phase C2（注入 UI + 接入 `ReSignModel.resign()` + 打包内置工具）。
- **不通过**（启动崩 / 定位没改）→ systematic-debugging（多半 ElleKit 加载顺序 / entitlements 缺项 / 某 appex 签名被系统拒）。

---

## Self-Review

**Spec coverage：**
- 放开 guard + 分类签名 → Task 1 ✓
- 可执行 bundle 各自 embedded.mobileprovision + 通配 entitlements；库不带 → Task 1 实现 + 测试断言 ✓
- 不改 bundle id / 不改注入 → 未触碰相关代码，Global Constraints 写明 ✓
- 确定性单测（合成 appex）→ Task 1 Step 1 ✓
- 真实 M3 PoC（不 strip）→ Task 2 ✓
- 末尾 `--verify --deep --strict` → Task 1 实现保留 + 测试断言 ✓
- 明确不做（app-group/推送/UI/打包/ldid）→ 未纳入本计划 ✓

**Placeholder scan：** 每步给出完整代码/命令。Task 2 为验收（需真账号 + 用户设备），Step 4 明确为人工计划外。无 TBD/TODO。

**Type consistency：** `AppResigner.resign(appDir:identity:profileData:entitlements:)` 签名不变；`CodesignInvocation.signArgs(identity:target:entitlements:)` / `verifyArgs(target:)`、`AppBundle.codeToSignInsideOut()` / `embeddedProfileURL()`、`Subprocess.run` 均与现有源一致。测试用 `TestTemp.dir()`、`TestSigningFixture`、`TemporaryKeychainIdentity`（现有）。
