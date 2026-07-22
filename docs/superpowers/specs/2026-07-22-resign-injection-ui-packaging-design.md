# 注入接入一键重签 + 插件选择 + 打包（Phase C2）—— 设计

> 前置：注入式重签 spec [2026-07-20-resign-injection-design.md]；注入核心 [plans/2026-07-20-resign-injection-plan1-core-and-poc.md]（`DylibInjector`/`MachOInspect` 已完成，真机 PoC 通过）；扩展签名 [specs/2026-07-22-resign-extension-signing-design.md]（Phase C1，已完成并真机验收——注入版 M3 定位生效）。本 spec 是 Phase C 的第二段：把已验证的注入链路从测试搬进产品 UI。

## 目标

在 `ReSignApp`（「重签助手」）里，让用户可选一个插件 dylib，一键完成「注入 + 通配签名（含扩展）→ 可装 IPA」；并把内置 `insert_dylib` + `ElleKit.dylib` 打进 app，装好后运行时能找到。不选插件时，一键重签行为与现状**完全一致**。

## 范围

- **做**：`ReSignModel` 注入分支（复用已验证的 `DylibInjector` 链路）+ `ReSignRootView` 可选插件行 + 内置工具随 app 打包/运行时定位。
- **不做**（边界）：多插件（先单个）、`.deb`/`.framework` 插件、开关类功能（文件访问/多开/去跳转）、畸形脱壳包（尾随字节/ldid）健壮性、A 档元数据编辑。

## 硬约束（沿用注入 spec）

- 输入 IPA 必须已解密（`cryptid==0`）、仅 arm64、只往干净（未注入）app 注入。违反 → 中文 banner，不产出半成品。
- 注入位置 `Payload/<App>.app/Frameworks/`；插件对 CydiaSubstrate 的依赖自动改指内置 ElleKit。
- FakeGPS/ElleKit 只进主 app，扩展不注入。
- 用户可见文案中文。平台 macOS(.v14)，swift-tools 5.9，`swift test` 全绿。

## 架构与组件

### 1. 模型注入接缝（`ReSignAppCore/ReSignModel.swift`）

`ReSignModel` 已有 `performResign` 闭包 + `resign()` 编排（建通配 profile → 签名 → 揭示）。新增一个**并列的、可注入的注入接缝**，保持可测：

- 新状态：`public var selectedPlugin: URL?`（可选插件 dylib）。
- 新可注入闭包：
  ```
  public var performInjection: (_ ipaURL: URL, _ plugin: URL) throws -> URL
      = ReSignModel.defaultPerformInjection
  ```
  返回**注入后的临时 IPA** URL。默认实现 `defaultPerformInjection`：解包 IPA（`ditto`）→ 定位 `Payload/*.app` → `xattr -cr` → `DylibInjector.preflight`（校验已解密/arm64/存在）→ `DylibInjector.inject(plugin:into:insertDylibTool:substrateReplacement:)`（内置工具来自 §3 的 `BundledInjectTools`）→ 重打包为临时 IPA（`ditto -c -k --sequesterRsrc --keepParent`）→ 返回该 IPA。
- `resign()` 改动（最小）：解析出 `ipa` 后，
  ```
  let toSign: URL
  if let plugin = selectedPlugin {
      log.append("注入 \(plugin.lastPathComponent)…")
      toSign = try performInjection(ipa, plugin)   // 失败落 catch → 中文 banner
  } else {
      toSign = ipa
  }
  ```
  其后 `buildAdHocProfile` 用**原 ipa 的 bundle id**（不变），`performResign` 改用 `toSign`。其余（离主线程、日志、揭示）不变。
- 输出命名：选了插件 → `<name>-injected.ipa`；未选 → 现状不变。
- 错误处理：`InjectError.encrypted` → 「该 IPA 仍加密，请先脱壳（cryptid≠0）」；`.badArch` → 「插件或主程序不是 arm64」；`.notApp/.notMachO` → 「IPA 结构异常/主程序非 Mach-O」；`.insertFailed` → 「注入失败：<原因>」。经 `UserFacingMessage`/banner，日志留痕，不产出半成品。

### 2. UI（`ReSignApp/ReSignRootView.swift`）

在 IPA 选择行**下方**加「插件（dylib，可选）」行：
- 拖拽 `.dylib` 或「选择」按钮（`NSOpenPanel`，限 `dylib`）→ 设 `model.selectedPlugin`。
- 选中后显示文件名 + 「×」清除按钮（置 nil）。
- 一键按钮文案：`selectedPlugin == nil` → 「一键重签」；否则 → 「注入并重签」。
- 忙碌/禁用逻辑沿用现有（无账号/无 IPA/busy 时禁用）。

### 3. 内置工具打包 + 运行时定位（`BundledInjectTools`）

现状：`insert_dylib` + `ElleKit.dylib` 在仓库 `Resources/inject/`，测试靠 CWD。产品需装好后运行时可定位。

- 把两件作为 **SwiftPM 资源**归 `ReSignAppCore` 目标（`.copy`），运行时经 `Bundle.module` 定位。新增 `BundledInjectTools`（`ReSignAppCore`）：`static var insertDylib: URL`、`static var ellekit: URL`，从 `Bundle.module` 解析；缺失则抛中文错误。
- 资源实际存放：`Sources/ReSignAppCore/Resources/inject/{insert_dylib,ElleKit.dylib}`（从仓库 `Resources/inject/` 迁入；保留 `README` 来源说明）。`Package.swift` 的 `ReSignAppCore` 加 `resources: [.copy("Resources/inject")]`。
- `scripts/package-resign.sh`：把 `swift build` 生成的 `ReSignAppCore_ReSignAppCore.bundle` 资源 bundle 拷进 `.app/Contents/Resources/`，使 `Bundle.module` 运行时可用。
- 受影响测试改定位：`InjectionPoCTests`（`ReSignAppCoreTests`）改用 `BundledInjectTools`；`DylibInjectorTests`（`ReSignKitTests`）改用迁移后的路径 `Sources/ReSignAppCore/Resources/inject/insert_dylib`（仍 CWD 相对，`ReSignKit` 层不引 `Bundle.module`）。

## 测试

- `ReSignModelTests`：注入编排——设 `selectedPlugin` + 注入假 `performInjection`（返回一个哨兵 URL）+ 假 `performResign`（断言收到的是注入返回的 URL 而非原 IPA）；未设插件时断言 `performResign` 收到原 IPA、`performInjection` 未被调用。用现有可注入闭包模式，不碰真签名/真注入。
- `defaultPerformInjection`：合成 arm64 `.app`（clang 造，复用 `DylibInjectorTests` 套路）+ 合成插件 dylib，端到端断言产出的临时 IPA 内主程序含注入的 `LC_LOAD_DYLIB`。用 `BundledInjectTools.insertDylib`。
- `BundledInjectTools`：断言 `insertDylib`/`ellekit` 可解析且文件存在、`insert_dylib` 可执行、`ElleKit.dylib` 含 arm64。
- 打包：`bash -n scripts/package-resign.sh`；构建后断言 `.app` 内存在资源 bundle 且含 `inject/insert_dylib`、`inject/ElleKit.dylib`。
- 全量 `swift test` 保持绿。gated 真机 PoC（`InjectionPoCTests`）仍可跑真实 M3 验收。

## 明确不做（Phase C2 边界，重申）

多插件、`.deb`/`.framework`、开关类功能、畸形脱壳包（ldid/尾随字节）、A 档元数据编辑、分支收尾（整个 C 方案完成后另议合并）。
