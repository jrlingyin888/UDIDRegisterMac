# 注入式重签（C 方案）v1 —— 设计

- 日期：2026-07-20
- 分支：`feature/resign-adhoc`（承接已完成的重签 + 通配 App ID 修法）
- 状态：设计已通过（待写 spec 审阅 + 实现计划）

## 目标

把工具从「重签器」升级为「注入式重签器」：给一个**干净、已解密**的 IPA 注入用户选的插件 `.dylib`（如 FakeGPS 这类 hook 插件），自动带上 substrate 运行时（ElleKit），再用已做好的**通配 App ID Ad Hoc** 流程签名，产出可装到测试设备的 IPA。解决用户当前「注入靠外部工具（锥子助手/TrollFools）+ 本工具只给 profile/p12」的割裂，做到账号/设备/通配/注入全在一个工具里自动完成。

上游：重签主线见 [2026-07-17-resignapp-design.md](2026-07-17-resignapp-design.md)；通配 App ID 修法已在 `feature/resign-adhoc` 落地（commit 9ded2d7，`resolveBundleIdForAdHoc` 显式优先、409 回退通配）。

## 范围与拆解

C 方案整体（市面级注入工具）拆成 3 个子项目，**本 spec 只做子项目 ①**：

| 子项目 | 内容 | 状态 |
|---|---|---|
| **① 核心注入（本 spec / v1）** | `.dylib` 注入 + 自带 ElleKit 运行时 + 通配签名 | 现在做 |
| ② 输入格式扩展 | `.deb` 解包取 dylib、`.framework` 嵌入 | 后续，复用 ① 的核心 |
| ③ 开关类改造 | 开启文件访问 / App 多开（改包名）/ 移除应用跳转 | 后续，本质是 Info.plist 编辑（与 A 档重叠） |

## 硬约束（必须写明）

- **输入 IPA 必须已解密**：App Store 原包主可执行文件是 FairPlay 加密的（`LC_ENCRYPTION_INFO(_64).cryptid != 0`）。加密二进制注入后装上跑不起来。工具**不做解密**（那需要越狱设备），只处理已脱壳的 IPA。注入前校验 `cryptid == 0`，否则明确报错。
- **只往干净 app 注入**：不支持重签「别人已注入过」的 app（例如 TrollFools 处理过的 M3——其注入二进制签名后有尾随数据，`codesign` 报 `internal error in Code Signing subsystem`，标准工具无法处理）。我们只往未注入的干净 app 注入、产出可控的干净二进制。
- **仅 arm64**：注入的 dylib 与目标须为 arm64（当前设备架构）。
- **不支持含扩展/Watch/App Clips 的 app**：复用现有 `ReSignError.unsupportedNestedBundle`。

## 架构

在 ReSignKit 新增一层「注入」，插在**解包之后、签名之前**，复用现有解包 / 通配签名（`AppResigner.codeToSignInsideOut` 由内向外）/ 重打包：

```
干净·已解密 IPA
  → 解包（现有 IPAResigner）
  → xattr -cr <app>（新增卫生步骤：清扩展属性，防 codesign internal error）
  → 注入（新增 DylibInjector）：
      ① 定位主程序 Payload/<App>.app/<CFBundleExecutable>，校验 cryptid==0
      ② 对每个插件 .dylib：
          - 拷入 Payload/<App>.app/Frameworks/<plugin>.dylib
          - 若插件依赖 CydiaSubstrate/libsubstrate → install_name_tool -change 指向自带 ElleKit
          - insert_dylib 给主程序插 LC_LOAD_DYLIB → @executable_path/Frameworks/<plugin>.dylib
      ③ 有 hook 插件 → 拷入自带 ElleKit.dylib，并保证其先于插件加载
  → 通配签名（现有流程，签名清单含新注入的 dylib + ElleKit）
  → 重打包
```

## 组件

### 1. `DylibInjector`（新增，ReSignKit）
纯注入逻辑，可独立测试。接口（示意）：
```
struct InjectableApp { let appDir: URL; let mainExecutable: URL }
enum InjectError: Error { case encrypted, badArch(String), notMachO(String), insertFailed(String) }

struct DylibInjector {
    /// 校验主程序已解密（cryptid==0）+ arm64
    static func preflight(appDir: URL) throws -> InjectableApp
    /// 注入一个插件 dylib（拷入 Frameworks + 修依赖 + 插 LC_LOAD_DYLIB）
    static func inject(plugin: URL, into app: InjectableApp, ellekit: URL?, needsRuntime: Bool) throws
}
```

### 2. 内置工具与运行时（打包资源）
- `Resources/inject/insert_dylib`：从开源 `insert_dylib` 构建的可执行；打包时随 app 一并 `codesign`（硬化运行时）。
- `Resources/inject/ElleKit.dylib`：ElleKit 开源项目的预编译 substrate 运行时；hook 插件注入时拷入目标 app。
- 二者版本与来源记录在 `Resources/inject/README`。

### 3. Mach-O 探测（新增，ReSignKit 或 UDIDRegisterKit）
读 `LC_ENCRYPTION_INFO(_64).cryptid`、CPU 架构、`LC_LOAD_DYLIB` 依赖列表——用 `otool -l` 解析（子进程），或最小 Mach-O 头解析。preflight 与依赖改写都要用。

### 4. 模型与 UI（ReSignAppCore + ReSignApp）
- `ReSignModel` 新增：`plugins: [URL]`（用户选的插件）；注入开关由「是否选了插件」隐式决定。
- `resign()` 流水线：选了插件时，在签名前调 `DylibInjector`。注入闭包可注入以便单测（同 `performResign` 模式）。
- UI：选完 IPA 后多一块「插件注入（可选）」——拖入/选择 `.dylib` 列表、显示已选、提示「hook 插件自动带 ElleKit」；「一键重签」时自动注入并签名。

## 「PoC 优先」——计划第 1 个任务

正式做 UI/流水线前，先手动/脚本跑通一条端到端，**去掉最大风险**（注入 + ElleKit + 免越狱装机是否真生效、是否 app 相关）：
1. 取一个**干净（未注入）的解密测试 IPA** + 一个具体插件（如 `FakeGPS.dylib`）+ 自带 ElleKit。
2. 按上面 ② ③ 手动执行：拷入、改依赖、insert_dylib、拷 ElleKit。
3. 通配签名（复用现有 `defaultPerformResign` + 通配描述文件）。
4. 装到用户测试设备，确认 hook 生效（如假定位真的改了）。

**用户需提供：** 干净解密 IPA + 具体插件 dylib + 测试设备。PoC 通过才进入正式实现；不通过则据现象调整方案（可能需换 ElleKit 版本/注入顺序/加载方式）。

## 错误处理

- 主程序 `cryptid != 0` → `InjectError.encrypted` → UI「此 IPA 未解密，无法注入，请用已脱壳的 IPA」。
- 插件非 arm64 / 非 Mach-O → `badArch` / `notMachO` → 明确报错。
- `insert_dylib` 失败 → `insertFailed(stderr)`。
- 含扩展/Watch → 复用 `unsupportedNestedBundle`。
- 签名阶段 `internal error in Code Signing subsystem`（若目标其实是已注入的脏 app）→ 给人话提示「此 IPA 可能已被其它工具注入，无法标准重签；请用干净 app」。

## 测试

- `DylibInjector.preflight`：合成含 `LC_ENCRYPTION_INFO cryptid=1` 的假二进制 → 断言抛 `encrypted`；cryptid=0 → 通过。
- `inject`：合成一个 arm64 dylib + 一个干净测试可执行，注入后用 `otool -l` 断言主程序多了指向该 dylib 的 `LC_LOAD_DYLIB`、且 dylib 已拷入 Frameworks/。
- 依赖改写：造一个依赖 `@rpath/CydiaSubstrate` 的假 dylib，注入后断言其依赖已改指向 ElleKit。
- `ReSignModel.resign()` 带插件：注入假的注入器闭包，断言选了插件时走注入分支、顺序正确。
- 端到端（PoC + 后续验收）：真设备装上、hook 生效。

## 明确不做（v1 边界）

`.deb` / `.framework` 输入；开关类改造（文件访问 / 多开 / 去跳转）；**解密**；**重签别人已注入的 app**；提取 / 移除已有插件；非 arm64；含扩展/Watch 的多子 bundle。
</content>
