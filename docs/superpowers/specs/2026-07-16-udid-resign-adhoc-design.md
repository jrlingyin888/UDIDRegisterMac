# ReSignApp：Ad Hoc 一键重签 —— 设计

- 日期：2026-07-16
- 分支：main（实现时另开 feature 分支）
- 状态：设计已通过

## 目标

现状痛点：管理员每次往苹果账号加了测试机 UDID 后，为了给新设备装 IPA，要手动去 Apple 后台重新生成描述文件 / p12，再拿去重签 IPA，很繁琐。

**一个纠正认知的前提**（决定了整个方案的重心）：

- **p12（证书）加设备时根本不用换**。证书有效期约 1 年，跟设备无关；而且苹果服务器上**从来没有你的 p12**——p12 = 证书 + 私钥，私钥只在你当初生成 CSR 的本机，Apple 只存公开的 `.cer`。所谓「从后台重下 p12」下的其实一直是同一张证书。
- **每次加设备后真正会变的，只有 Ad Hoc 描述文件（`.mobileprovision`）**，因为它内嵌 UDID 列表。

所以目标是：做一个 **app 内一键重签**——自动用同一套 `.p8` 刷新出「含全部设备的最新 Ad Hoc 描述文件」，配合本机证书对 IPA 重签，直接产出可安装的 IPA。

## 关键决定（已与用户确认）

| 决定项 | 结论 |
|---|---|
| 功能深度 | **全流程 app 内一键重签**，产出可直接安装的 IPA |
| 证书 | **app 帮忙创建**（本机生成密钥对 + CSR + 拉证书 + 组装），可选导出 p12 |
| 工程结构 | **同一仓库**，新建独立 **不沙盒** 的 `ReSignApp` target，**共享** `UDIDRegisterKit` |
| 签名类型 | **Ad Hoc**（iOS Distribution 证书 + Ad Hoc 描述文件，内嵌设备列表） |
| bundle ID | v1 **不改**（同 bundle ID）；改写留到以后 |
| 账号共享 | **App Group + 共享钥匙串组**：两 app 共享账号，只录一遍 |

**为什么分成独立 app 而不是加个 Tab**：这不是代码量问题，而是**安全模型冲突**。现有注册 app 的骨架和卖点是「App Sandbox 最小权限、纯本地、只申请两项权限」；而重签核心必须调 `codesign`/`ditto`、动本机钥匙串，几乎必然要放开沙盒。把重活塞进干净的注册 app 会改变它对外宣称的安全模型、扩大攻击面。因此两者是「两种安全人格」，分开是对的；但放同一仓库、共享 Kit，可避免账号/API 代码重复维护。

## 工程结构

```
UDIDRegisterMac (同一个 repo / Package.swift)
├─ UDIDRegisterKit   [库·纯网络+模型]  扩展：certificates / profiles / bundleIds API + CSRBuilder
├─ ReSignKit         [库·动本机签名]   新增：临时钥匙串、codesign 编排、IPA 解包/打包、entitlements
├─ UDIDRegisterApp   [沙盒·现有]       基本不动；仅为共享账号加 entitlements + 一次性数据迁移
└─ ReSignApp         [不沙盒·新增]     新 SwiftUI：选账号→建/选证书→选IPA→自动出profile→重签→产出IPA
```

**分层原则**：`UDIDRegisterKit` 保持「只做网络 + 纯函数、可单测、无副作用」；一切要 shell-out（`codesign`/`ditto`）或碰钥匙串的「脏活」隔离在 `ReSignKit`。`ReSignApp` 同时依赖两个库。每层职责单一、可独立理解与测试。

## 三个核心流程

### 1. 证书创建（app 帮你建）

1. 本机用 Security 框架生成 **RSA-2048 密钥对**（`SecKeyCreateRandomKey`），私钥不出机。
2. 在 `UDIDRegisterKit` 里**手写 PKCS#10 CSR**（ASN.1 DER 编码 + 私钥自签名）。不 shell-out openssl——纯 Swift、可单测、不落临时私钥文件。
3. `POST /v1/certificates`（`certificateType: DISTRIBUTION`）提交 CSR → 拿回 `.cer`（DER，`attributes.certificateContent` base64）。
4. 私钥 + `.cer` 组成签名身份：导入一个**临时钥匙串**供本次签名使用；可选 `SecItemExport` 导出 `.p12` 给用户留底。
5. 已存在可用证书时可直接**复用**（`GET /v1/certificates` 列出选择），不必每次新建。

> ⚠️ **实现风险点（重点对待）**：codesign 使用导入私钥时 macOS 默认弹密码框。因密钥是进程内自生成、导入到我们自建的临时钥匙串，可通过 `security set-key-partition-list` 把使用权授给 `/usr/bin/codesign`，实现**无弹窗签名**。这是最容易踩坑处，需专门验证。

### 2. 描述文件自动刷新（每次真正在变的东西）

复用现有 `.p8` JWT（`ASCJWT` / `ASCClient` 那套）：

读 IPA 内 `Info.plist` 的 bundle ID → `GET/POST /v1/bundleIds` 确保 App ID 存在 → `GET /v1/devices` 取账号下**全部设备** → 删除旧同名 profile（profile 不能改，只能删+建）→ `POST /v1/profiles`（`profileType: IOS_APP_ADHOC`，关联 bundleId + 证书 + 全部设备）→ 拿回最新 `.mobileprovision`。

**加了新设备后，这一步自动带上它**——这正是替代「手动去后台重打包」的核心。

### 3. 重签引擎（ReSignKit）

1. `ditto -x -k` 解包 IPA 到临时目录，定位 `Payload/*.app`（`ditto` 正确保留符号链接与可执行位，比第三方 zip 库稳）。
2. **由内向外**枚举需签名的代码：`Frameworks/*.dylib`、`Frameworks/*.framework`、`PlugIns/*.appex`、`Watch/*.app` 及其嵌套，**主 app 最后**。
3. 每个可执行 bundle 换上对应的 `embedded.mobileprovision`；**entitlements 直接从该 profile 内抽取**（保证绝不声明 profile 未授权的权限）写成临时 `entitlements.plist`。
4. `codesign --force --sign <identity> --entitlements <plist>` 逐层签名（framework/dylib 不带 entitlements）。
5. `codesign --verify --deep --strict` 校验。
6. `ditto -c -k --sequesterRsrc --keepParent` 重新打包为 `.ipa`；在 Finder 中显示，并可选一并导出 p12。

### 含扩展/Watch 的应用

若检测到 `.appex` / `Watch app` 带**各自独立的 bundle ID**，需为每个 bundle ID 各建一份 Ad Hoc 描述文件并分别签入（API 调用相应增多）。嵌套签名本身（framework/dylib/appex/watch 由内向外）是 codesign 正确性的硬要求，v1 即包含。

## 账号共享（App Group + 共享钥匙串组）

现有注册 app 是沙盒的：`accounts.json`（元数据）落在沙盒容器内，`.p8`（钥匙串条目）绑定沙盒 access group。不沙盒的新 app **默认都看不到**。为「只录一遍」，两 app（同 Team）都声明：

- 同一个 **App Group**（如 `group.com.pangu.udidregister`）：`accounts.json` 改存共享容器 `containerURL(forSecurityApplicationGroupIdentifier:)`。
- 同一个 **keychain-access-group**：`KeychainSecretStore` 设置 `kSecAttrAccessGroup`，`.p8` 存共享钥匙串组。

**对现有 app 的改动（本方案唯一动到注册 app 的地方）**：

- entitlements 增加 App Group + keychain-access-groups 两项。
- `AccountStore.defaultFileURL()` 改为指向 App Group 容器；`KeychainSecretStore` 增加 access group 参数。
- **一次性迁移**：注册 app 下次启动时，若旧容器/旧钥匙串组有数据而共享位置为空，则搬迁过去（保证老用户账号不丢）。

## v1 范围 vs 以后

**v1 做**：Ad Hoc · 同 bundle ID · 建证书（可导 p12）· 自动刷 profile 带全部设备 · 含 framework/appex/watch 的嵌套重签 · 产出可安装 IPA · 账号跨 app 共享。

**以后（明确不在 v1）**：

- 改写 bundle ID（拿别人 IPA / 换新 ID 重签）。
- Development 签名类型。
- 自动开通 App ID 能力（推送 / App Groups / iCloud 等）——**v1 遇到能力不匹配给明确报错，而非默默失败**。
- OTA 安装清单 / 直接装到设备（v1 只产出 IPA，安装沿用你现有方式，如 Apple Configurator）。

## 错误处理要点

- **能力不匹配**：原 app 用了 App ID 未开通的能力（如推送），重签后 entitlements 与 profile 不符会导致装机失败。因 entitlements 从 profile 抽取，v1 检测到原 app 声明了 profile 未含的关键 entitlement 时**明确报错并指出原因**。
- **codesign 弹窗**：见上「实现风险点」，用 partition-list 授权规避。
- **设备满 100**：`POST /v1/profiles` 或建设备时超额，透传 ASC 的额度错误（复用现有 `UserFacingMessage` 风格）。
- **网络 / JWT 失效**：复用 `ASCClient` 现有错误路径与 `ASCError`。
- **IPA 结构异常**（无 `Payload`、非 zip）：ReSignKit 前置校验，早失败早提示。

## 测试策略

- `UDIDRegisterKit`：`CSRBuilder` 生成的 DER 可被标准解析器验证（单测，无网络）；新 API 方法的请求体/URL 构造单测（沿用现有 `HTTPClient` 可注入的模式）。
- `ReSignKit`：解包/entitlements 抽取/打包用固定小样本 IPA 做单测；codesign 编排以「命令拼装」为纯函数便于断言，真实签名走手动/集成验证。
- 端到端：用一台真实测试机，加一个新 UDID → 一键重签 → 装机成功，作为验收标准。

## 分发说明

`ReSignApp` 不沙盒，但仍走 **Developer ID 签名 + 公证**（非 Mac App Store，允许不沙盒）。`scripts/package.sh` 需扩展为可分别打包两个 app（或产出各自 DMG）。运行时创建临时钥匙串、spawn `codesign` 对已公证的不沙盒 app 属正常行为。
