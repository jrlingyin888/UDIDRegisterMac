# ReSignApp（重签助手）—— 设计

- 日期：2026-07-17
- 分支：`feature/resign-adhoc`（承接 Plan 1 签名 API + ReSignKit 引擎）
- 状态：设计已通过

## 目标

把已完成的两个库层（`UDIDRegisterKit` 签名 API + `ReSignKit` 重签引擎）串成一个**能用的 app**：管理员选账号 → 确保有签名证书 → 选一个 IPA → **一键**自动刷新「含全部设备的 Ad Hoc 描述文件」并重签 → 产出可直接安装的 IPA。解决「加了设备就得手动去后台重打包描述文件、重签」的麻烦。

上游设计见 [2026-07-16-udid-resign-adhoc-design.md](2026-07-16-udid-resign-adhoc-design.md)；库层进度见 [../2026-07-16-resign-progress-handoff.md](../2026-07-16-resign-progress-handoff.md)。

## 关键决定（已与用户确认）

| 决定项 | 结论 |
|---|---|
| 账号共享 | **配置文件导入**（复用现成 `AccountConfig` 导出/导入）——ReSignApp 有自己的账号库，零改动现有 app、零 App Group、零迁移 |
| 证书 | **两种都支持**：app 自建并长期持有 · 导入已有 p12 |
| UI | **单窗口**，沿用注册 app 风格；一个「一键重签」按钮跑完整流水线 + 进度日志 |
| 打包 | **ReSignApp 单独一个 DMG**（不沙盒、硬化运行时、Developer ID 签名 + 公证） |
| 安装到设备 | v1 只产出 IPA，安装沿用现有方式（Apple Configurator 等）——不在本 app |

## 架构

新增**不沙盒**的可执行 target `ReSignApp`，复用两个库：

```
ReSignApp (不沙盒)
├─ 复用 UDIDRegisterKit：AccountStore / KeychainSecretStore / ASCClient(签名API) /
│                        SigningKeyPair / AccountConfig(导入)
├─ 复用 ReSignKit：TemporaryKeychainIdentity / IPAResigner(profile-first) / ProvisioningProfile
└─ 新增本 app 自己的：SigningIdentityStore · ReSignModel · 视图
```

不沙盒的原因同库层设计：要 spawn `codesign`/`security`/`ditto`。

## 组件

### 1. `SigningIdentityStore`（签名身份的持久化）
按账号（`AppleAccount.id`）持久化一套**可复用的签名身份**，存进 ReSignApp 自己的钥匙串（用 ReSignApp 的 bundle id 作 service）。

一条签名身份 = `{ privateKeyDER: Data, certificateDER: Data, ascCertificateId: String }`：
- **privateKeyDER**：`SecKeyCopyExternalRepresentation`(私钥) 的 RSA 私钥 DER；用时 `SecKeyCreateWithData` 还原成 `SecKey`，配 `certificateDER` 交给 `TemporaryKeychainIdentity`。
- **ascCertificateId**：构建描述文件时 `createAdHocProfile` 需要引用证书的 ASC 资源 id。

两条入口：
- **自建**：`SigningKeyPair.generateRSA2048()` → `makeCSR` → `ASCClient.createCertificate(csrDER:type:.distribution)` → 拿 `CertificateInfo{contentDER, id}` → 存。发布证书有数量上限，**一个账号建一次、长期复用**（已存在就不再建）。
- **导入 p12**：用户选 `.p12` + 输入密码 → `SecPKCS12Import` → `SecIdentity` → `SecIdentityCopyPrivateKey` + `SecIdentityCopyCertificate`→DER。**再用 `ASCClient.listCertificates(.distribution)` 按序列号/内容匹配出该证书的 ASC 资源 id**；账号上找不到该证书则报错（描述文件必须引用账号上已注册的证书）。

接口（示意）：
```
struct SigningIdentity { let privateKeyDER: Data; let certificateDER: Data; let ascCertificateId: String }
protocol SigningIdentityStore {
    func identity(for accountID: UUID) -> SigningIdentity?
    func createAndStore(for account: AppleAccount, cred: ASCCredentials, client: ASCClient) async throws -> SigningIdentity
    func importP12(_ data: Data, password: String, for account: AppleAccount, cred: ASCCredentials, client: ASCClient) async throws -> SigningIdentity
    func exportP12(for accountID: UUID, password: String) throws -> Data
    func remove(for accountID: UUID) throws
}
```

### 2. `ReSignKit` 小增补：读 IPA 的 bundle id
流水线要在重签**之前**拿 bundle id 去建描述文件。给 `IPAResigner` 加一个 peek 助手：
```
static func readBundleIdentifier(ipaURL: URL) throws -> String   // 解出 Payload/*.app/Info.plist 的 CFBundleIdentifier
```

### 3. `ReSignModel`（`@MainActor @Observable`，编排）
状态：`accounts`（自己的 `AccountStore`）、`selectedID`、`identityStatus`、`selectedIPA: URL?`、`log: [String]`、`busy`、`banner`。
动作：账号增删/导入、签名身份 创建/导入/导出、`resign()`（下面的流水线）。用可注入的 `ASCClient` / `SigningIdentityStore` / 重签器闭包，便于单测编排。

### 4. 视图（单窗口，沿用 `RootView` 结构）
- 顶部：账号 `Picker` + 「管理账号…」(sheet：导入配置文件 / 列表 / 删除) + 额度文案。
- 签名身份区：状态徽章（✅ 已就绪 / ⚠️ 未创建）+ 按钮「自动创建」「导入 p12…」「导出 p12…」。
- IPA 区：拖入区 + 「选择…」，显示已选文件名。
- 「一键重签」大按钮 → 进度日志区 → 完成后「在 Finder 中显示」。

## 「一键重签」流水线

点「一键重签」后，`ReSignModel.resign()` 顺序执行（每步 append 到 `log`）：
1. 取当前账号凭据；没有签名身份 → 提示「先自动创建或导入 p12」并中止。
2. `IPAResigner.readBundleIdentifier(ipaURL)` 得 bundle id。
3. `client.findOrCreateBundleId(identifier: bundleId, name: bundleId)` → bundleId 资源。
4. `client.listDevices` 取全部设备 → `deviceIds = rows.map(\.id)`。
5. `client.refreshAdHocProfile(name: "ReSign AdHoc \(bundleId)", bundleIdResourceId:, certificateId: identity.ascCertificateId, deviceIds:)` → `ProfileInfo{contentData}`。**加了新 UDID 在这一步自动纳入。**
6. `SecKeyCreateWithData(identity.privateKeyDER)` → `TemporaryKeychainIdentity(privateKey:, certificateDER: identity.certificateDER, commonName:)`；`defer identity.cleanup()`。（`commonName` 只作 p12 友好名的**标签**——ReSignKit 现在按证书 SHA-1 指纹签名，不依赖 CN；传账号 `displayName` 即可。）
7. `IPAResigner.resign(ipaURL:, outputURL:, identity:, mobileprovisionData: profile.contentData)`（entitlements 从描述文件抽取，绝不越权）。
8. `NSWorkspace.activateFileViewerSelecting([outputURL])`。

输出路径：默认与源 IPA 同目录、`<原名>-resigned.ipa`，已存在则覆盖（不沙盒可直接写）。v1 不弹保存面板。（**计划 4 决策增量 A 细化**：源目录不可写时退回 `~/Downloads`。）

## 错误处理

- **含扩展/Watch/App Clips**：`IPAResigner` 抛 `ReSignError.unsupportedNestedBundle` → UI 显示「暂不支持含扩展/Watch 的 app（后续版本支持）」。
- **导入 p12 但账号上无此证书**：`SigningIdentityStore.importP12` 报「该 p12 的证书未在此账号注册，无法用于构建描述文件」。
- **设备满 100 / JWT 失效 / 网络**：透传 `ASCError`，走 `UserFacingMessage`。
- **IPA 结构异常**（无 `Payload/*.app`）：`ReSignError.appNotFound` → 「不是有效的 IPA」。
- **能力不匹配**：v1 用「描述文件派生的 entitlements」保证不越权、签名自洽；对「原 app 声明了描述文件未含的能力」这类**欠配**只做已知限制说明，不做深度比对（留后续）。

## 打包

新增 `scripts/package-resign.sh`（或把 `package.sh` 参数化）：`swift build -c release --product ReSignApp` → 拼 `.app`（**ReSignApp 自己的 Info.plist + bundle id + 图标**）→ `codesign --options runtime`（**不带沙盒 entitlements**，用一份空/最小 entitlements）→ DMG「重签助手」→ `notarytool` 公证 → `stapler`。ReSignApp 需要自己的 bundle id 常量（用作其钥匙串 service），与注册 app 的 `AppIdentifiers.bundleID` 分开。

## 测试

- `SigningIdentityStore`：存取往返（用测试钥匙串或内存实现）、p12 导入解析、证书 id 匹配逻辑（可注入假 `ASCClient`）。
- `ReSignModel.resign()`：注入假 `ASCClient`（返回预置 profile）+ 假重签器闭包，断言流水线顺序、`unsupportedNestedBundle`/无身份/满额度等错误分支。
- `IPAResigner.readBundleIdentifier`：合成 IPA 读回 bundle id（集成，`ditto` 在场）。
- 端到端：真账号 + 真 IPA + 真机安装成功，作为验收。

## 计划 4 决策增量（2026-07-17，已与用户确认）

规格上方为大方向；下面是进入实现（计划 4）时细化/新增的决定。

### A. 输出路径解析（细化「输出路径」）
把 `ReSignModel.resign()` 里固定的输出路径换成**可注入、可单测**的 `resolveOutputURL(for:)`：
- 先试源 IPA 同目录；`FileManager.default.isWritableFile(atPath:)` 判其父目录可写 → 用同目录 `<原名>-resigned.ipa`。
- 父目录不可写（如挂载的只读 DMG）→ 退回 `~/Downloads/<原名>-resigned.ipa`，日志说明「源目录只读，已输出到下载文件夹」。
- 已存在则覆盖，文件名规则不变。v1 仍不弹保存面板。

### B. ⚠️ 生产证书泄漏必修（`TemporaryKeychainIdentity`）
`security import` 会往**登录钥匙串**留一份用户真实证书的副本，`delete-keychain` 删不掉。安全修法——**只删我们新增那份，绝不碰用户自己的**：
- `init` 里 import **之前**，用叶证书 SHA-1（复用已有 `signingIdentity` 指纹）在登录钥匙串快照是否已存在（`security find-certificate -a -Z <login>` 输出里 grep 该 SHA-1）→ 记 `certPreexistedInLogin`。
- `cleanup` 里**仅当** `!certPreexistedInLogin` 才执行一次 `security delete-certificate -Z <sha1> <login>`。
- 集成测试验证：自签证书重签→cleanup 后登录钥匙串查不到该 SHA-1。现有「测试跑完清理泄漏证书」的兜底可保留，但修好后不应再依赖它。

### C. `exportP12`（补齐计划 3 推迟项）
- `SigningIdentityManager.exportP12(for accountID:, password:) throws -> Data`：从 store 取 `SigningIdentity` → openssl 把 PKCS#1 私钥 DER + 证书 DER 组回 `.p12`（`openssl rsa`/`x509` 转 PEM → `openssl pkcs12 -export`，**密码走 stdin 不进 argv**），中间明文产物 shred。对称于现有 `importP12`。
- `ReSignModel.exportP12(to url:, password:) -> Bool`：包一层写到用户选的路径，失败置 `banner`。
- 单测：导出的 p12 用同密码 openssl 能解回，私钥/证书与存的一致。

### D. SwiftUI 界面 + `@main`（替换占位 `main.swift`）
沿用注册 app 结构（`AppDelegate.setActivationPolicy(.regular)`）：
- `ReSignApp.swift`：`@main` + `AppDelegate` + 构造 **live 版 `ReSignModel`**（真 `AccountStore`/`KeychainSecretStore`/`SigningIdentityManager(KeychainSigningIdentityStore)`/`ASCClient`，仿 `AppModel` 接线；新增 `ReSignModel.live()` 工厂，View 不硬接线）。
- `ReSignRootView.swift`：账号 `Picker` +「管理账号…」sheet（导入配置文件/列表/删除）+ 签名身份区（状态徽章 + 自动创建/导入 p12…/导出 p12…）+ IPA 拖入区（`.dropDestination` 收 `.ipa`）+「一键重签」大按钮 + 进度日志 +「在 Finder 中显示」。
- 导入/导出 p12 的密码用带 `SecureField` 的小 sheet。

### E. 图标 + 打包（做到「可交付前」）
- 改 `scripts/make-icon.swift`（参数化或加第二产物）出一版**区分配色/字形**的图标 → `Resources/ReSignAppIcon.icns`。
- 新增 `Resources/ReSignApp-Info.plist`（名「重签助手」、bundle id `com.pangu.ReSignMac`、executable `ReSignApp`、icon `ReSignAppIcon`）+ `Resources/ReSignApp.entitlements`（**空/最小、不含 app-sandbox**，硬化运行时靠 `--options runtime`）。
- 新增 `scripts/package-resign.sh`（**独立脚本**，不改现有可用的 `package.sh`），仿其结构：`swift build -c release --product ReSignApp` → 拼 .app → `codesign --options runtime` → DMG「重签助手」→ `notarytool` → `stapler`。

### F. 本轮范围与验证
- 本会话做到**可交付前全部**：A–E 全实现，`swift build` + `swift test`（新增 exportP12 / 输出路径 / 泄漏修复用例，保持全绿）+ `swift run ReSignApp` 启动冒烟。
- **公证需 `DEV_ID_APP` + `NOTARY_PROFILE` 凭据、真机 E2E 需真账号 + 测试机**——这两步由用户按脚本/清单执行，不在本会话自动完成。

## 明确不做（v1 边界）

改写 bundle ID、Development 签名、含扩展/Watch 的多子 bundle 各自描述文件、OTA/装机、能力欠配深度比对、App Group 无感账号共享——都留到后续。
