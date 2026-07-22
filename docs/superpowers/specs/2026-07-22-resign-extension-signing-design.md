# 扩展感知的通配签名（Phase C1）—— 设计

> 前置：注入式重签 spec [2026-07-20-resign-injection-design.md] + 计划 1 [plans/2026-07-20-resign-injection-plan1-core-and-poc.md]（注入核心 Task 1-3 已完成，PoC 在 Invis 上自动化+真机双验证通过）。本 spec 是 Phase C 的第一段（用户已选「先做引擎扩展签名」）。

## 目标

让 ReSignKit 签名引擎能用**一张通配 Ad Hoc 描述文件**签含嵌套可执行 bundle（App 扩展 `*.appex` / Watch app）的 app，从而让真实 app 能被重签（和注入）。当前 `AppResigner` 的 `nestedExecutableBundles` guard 直接拒签带扩展的 app（`unsupportedNestedBundle`），而真实 app 几乎都有扩展——这是工具能否用于真实 app（如带 2 个 appex 的 M3）的关键缺口。

**验收靶子**：把 FakeGPS 注入干净·已解密的 `移动办公M3-5.0.0.ipa`（M3 有 CMPCallDirectory + CMPSharePublish 两个 appex）→ 通配签名（含扩展）→ 产出可装 IPA → 用户真机验证 FakeGPS 定位生效。

## 背景：为什么通配能签扩展

- **显式 App ID** 下每个 appex 要各自的 App ID + 描述文件——这是原 guard 拒签的理由。
- **通配 App ID `*`**（资源 `SYBWQ53DXF`，`application-identifier T46A6Q874U.*`）一张描述文件**通配所有 bundle id**，天然覆盖主 app + 所有 appex。
- 引擎已有由内向外签的机制：`AppBundle.codeToSignInsideOut()` 已收集 `Frameworks/*.{framework,dylib}` + `PlugIns/*.appex` + `Watch/*.app`（及 watch 内层）+ 主 app（主 app 最后）。**只差**：放开 guard + 给每个可执行 bundle 塞 profile + 带 entitlements 签。

## 真实 M3 的 entitlements（设计依据）

主 app 与两个 appex 原本都用了通配 ad-hoc profile **不授予**的权限：`aps-environment`、`com.apple.developer.associated-domains`、`com.apple.developer.networking.wifi-info`、`com.apple.security.application-groups`（主 app 与 CallDirectory 靠 `group.com.seeyon.m3....CallDirectory` 共享）。通配 profile 只给：`application-identifier T46A6Q874U.*`、`com.apple.developer.team-identifier T46A6Q874U`、`keychain-access-groups T46A6Q874U.*`、`get-task-allow=false`。

**关键**：主 app **现有行为**就是「只用通配 profile 的 entitlements、丢掉推送/深链/app-group」在签（`AppResigner` 用 `profile.entitlements`）。故扩展只要照主 app 一样处理即一致——这也是本设计所采方案。

## 架构与改动

改动集中在 **`Sources/ReSignKit/AppResigner.swift`**（+ 一个 `AppBundle` 小助手）。

### 目标分类

签名循环遍历 `codeToSignInsideOut()`（由内向外）。每个目标 `t` 分两类：

- **可执行 bundle**（需 profile + entitlements）：`t == appDir`（主 app）**或** `t.pathExtension == "appex"` **或** `t.pathExtension == "app"`（Watch app）。
- **库**（不塞 profile、不带 entitlements）：其余（`*.framework` / `*.dylib`）。

（Watch 内层 appex 也是 `.appex`，被上面命中；统一处理，无需特判。）

### 签名规则

- 对**可执行 bundle**：
  1. 把通配 profile 写到**该 bundle 自己**的 `embedded.mobileprovision`（每个可执行 bundle 都必须自带一份；主 app 的那份不覆盖 appex）。
  2. `codesign --sign <指纹> --entitlements <ent.plist> --keychain <临时钥匙串> <bundle>`，`ent.plist` = **通配 profile 的 entitlements**（对所有可执行 bundle 用同一份）。
- 对**库**：`codesign --sign <指纹> --keychain <临时钥匙串> <lib>`（不带 entitlements，照旧）。
- 由内向外顺序不变（appex/framework 先，主 app 最后）。
- 末尾仍 `codesign --verify --deep --strict <主 app>`，递归校验整棵嵌套签名树。

### 不改的

- **不改任何 bundle id**：通配 profile 通配所有 id，原 id 天然满足苹果「appex id = 主 app id.后缀」规则；改 id 反而会破坏该关系。
- **不改注入逻辑**：FakeGPS + ElleKit 只进主 app 的 `Frameworks/`，扩展不注入（FakeGPS hook 的是主 app 的定位）。
- **`application-identifier` 用 `T46A6Q874U.*`**（通配），已由 Invis PoC 证明可装可启动。

### 接口变化

- `AppBundle`：加分类助手（如 `func isExecutableBundle(_ url: URL) -> Bool` 或在 `AppResigner` 内联判断）+ 每-bundle 的 `embeddedProfileURL(for:)`（现有 `embeddedProfileURL()` 只给主 app）。
- `AppResigner.resign(appDir:identity:profileData:entitlements:)` 签名不变；内部去掉 `unsupportedNestedBundle` 抛出，改为支持。`ReSignError.unsupportedNestedBundle` 可保留（Watch/AppClip 若后续发现不支持的形态仍可用）或降级为不再触发。

## 错误处理

- 某个可执行 bundle 签名失败 → `ReSignError.codesignFailed("<bundle 名>: <stderr>")`（沿用现有）。
- 末尾 `--verify --deep --strict` 失败 → `ReSignError.codesignFailed("verify: <stderr>")`。
- 遇到确实不支持的嵌套形态（例如未来发现某类 bundle 无法通配签）→ 保留 `unsupportedNestedBundle` 语义，给人话中文报错。

## 测试

- **确定性单测（扩展 `AppResignerTests`）**：造一个含**合成 appex**的 `.app`（clang 造主程序 + appex 可执行 + 各自 Info.plist），用 `TestSigningFixture` 身份 + 测试用描述文件重签。断言：(1) appex 被签上（`codesign --verify` 该 appex 通过）；(2) appex 目录有自己的 `embedded.mobileprovision`；(3) appex entitlements = 通配那套；(4) 整体 `--verify --deep --strict` 通过。不依赖真账号。
- **真实 PoC（`InjectionPoCTests`，不带 `POC_STRIP_PLUGINS`）**：`POC=1 POC_IPA=移动办公M3-5.0.0.ipa POC_PLUGIN=FakeGPS.dylib` → 走新扩展签名路径 → 产出 `~/Downloads/移动办公M3-5.0.0-injected.ipa`，断言产物存在 + `codesign --verify --deep --strict` 通过 + 两个 appex 各有 embedded.mobileprovision。→ 用户装机验证 FakeGPS 定位。
- 全量 `swift test` 保持绿。

## 明确不做（Phase C1 边界）

- **app-group 保留 / 推送 / 深链 / wifi-info**：通配 ad-hoc 不授权，与主 app 一致丢弃 → 扩展的 app-group 共享类功能可能不工作（**对改定位无影响**）。要保留需在账号注册 App Group + 加进 profile，成本高、跨团队前缀不一定有效，留后续。
- **注入 UI、打包内置 insert_dylib/ElleKit**：→ Phase C2。
- **畸形脱壳包（尾随字节/ldid）健壮性**：如 `M3Z3632干净脱壳.ipa` 的 GMObjC 畸形；→ 后续「签名健壮性」。
- **`.deb` 解包 / `.framework` 插件 / 开关类功能**：→ v2/v3。
- **Watch app**：逻辑上统一处理（`.app` 也走可执行 bundle 分支），但无 Watch 材料，本段不专门验证。
