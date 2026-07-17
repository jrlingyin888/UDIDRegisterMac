# 重签功能 —— 进度与交接（handoff，2026-07-17）

> 取代 [2026-07-16-resign-progress-handoff.md](2026-07-16-resign-progress-handoff.md)（那份是 ReSignKit 完成时的状态）。

- 分支：`feature/resign-adhoc`（**未合并、未推送**；从 `main` @ `17b5ff9` 分出，共 40 提交）
- 当前 HEAD：`15da8a5`，`swift test` = **90/90 全绿**
- 状态：三层里**两个半完成**——两个库层 + ReSignApp 核心逻辑都done；**只剩 ReSignApp 的 UI + 打包（计划 4）**。目前无任何可点界面，未改动现有注册 app。

## 背景（一句话）

加测试机 UDID 后，为给新设备装 IPA 要手动去后台重打包描述文件再重签。真相：证书加设备不用换、苹果也没有你的 p12，**每次真正变的只有 Ad Hoc 描述文件**。目标：app 内一键重签——自动用同一套 `.p8` 刷新「含全部设备的最新 Ad Hoc 描述文件」，配 app 持有的证书对 IPA 重签，产出可安装 IPA。

设计：[specs/2026-07-16-udid-resign-adhoc-design.md](specs/2026-07-16-udid-resign-adhoc-design.md)（总）+ [specs/2026-07-17-resignapp-design.md](specs/2026-07-17-resignapp-design.md)（ReSignApp）。

## 已完成（都在分支上，90 测试）

1. **UDIDRegisterKit 签名 API**（[plan1](plans/2026-07-16-resign-plan1-kit-signing-api.md)）：CSR/密钥对、建证书/BundleId、`refreshAdHocProfile`（删旧建新、自动带全部设备）。openssl 验签过。
2. **ReSignKit 引擎**（[plan2](plans/2026-07-16-resign-plan2-resignkit-engine.md)）：`TemporaryKeychainIdentity`（**无弹窗** codesign：SHA-1 指纹签名 + set-key-partition-list，**绝不 add-trusted-cert**）、`ProvisioningProfile`、`AppResigner`、`IPAResigner`（含 profile-first 入口 + `readBundleIdentifier` peek）。真机 e2e 验证过；含扩展/Watch/App Clips 的 app 明确报错。
3. **ReSignAppCore 核心逻辑**（[plan3](plans/2026-07-17-resignapp-plan3-core.md)）：
   - `SigningIdentity`{privateKeyDER, certificateDER, ascCertificateId} + `KeychainSigningIdentityStore`（ThisDeviceOnly）+ `SigningKeyCodec`（SecKey↔PKCS#1 DER）。
   - `SigningIdentityManager`：`createAndStore`（app 自建证书）+ `importP12`（**用 openssl 抽 key/cert，不碰 Security import、不污染钥匙串**；密码走 stdin；按证书内容匹配账号上的 ASC 证书 id）。
   - `ReSignModel`（@Observable）：自己的账号库、`importAccountConfig`（复用现成 AccountConfig）、`createIdentity()`/`importP12(from:password:)`/`resign()`。`resign()` 三个可注入闭包（readBundleID/performResign/revealInFinder）→ 全可单测，不碰真实 codesign/钥匙串/Finder。

## 下一步：计划 4（ReSignApp UI + 打包）—— 下次会话 brainstorm/plan/实现

UI 决策已在 [ReSignApp spec](specs/2026-07-17-resignapp-design.md) 定好（单窗口、沿用 RootView 风格、账号导入配置文件、证书两种、单独 DMG）。计划 4 要做：

1. **SwiftUI 视图 + @main**（在 `Sources/ReSignApp/`，替换现有占位 main.swift）：账号 Picker+管理(导入配置/删除)、签名身份区(状态徽章 + 自动创建/导入 p12/导出 p12 按钮)、IPA 拖入/选择、「一键重签」+ 进度日志 + 「在 Finder 显示」。驱动 `ReSignModel` 已有的 public 方法。
2. **exportP12**（计划 3 有意推迟）：给 `SigningIdentityManager`/`ReSignModel` 加导出——用 openssl 把存的 key+cert 组回 p12 让用户留底。
3. **⚠️ 生产证书泄漏必修**：`TemporaryKeychainIdentity` 重签时 `security import` 会往用户**登录钥匙串**留一份他们**真实**证书的副本（测试路径已按 SHA-1 清理，生产没有）。**安全修法**：init 里在 import **前**先 `security find-certificate -Z <sha1> login.keychain-db` 快照该证书是否已存在；cleanup 里**仅当**导入前不存在才 `delete-certificate -Z` **删一次**（只删我们新增那份，绝不删用户自己的）。真机测试时验证。
4. **打包** `scripts/package-resign.sh`：`swift build -c release --product ReSignApp` → 拼 .app（**ReSignApp 自己的 Info.plist + bundleID `com.pangu.ReSignMac` + 图标**）→ `codesign --options runtime`（**不带沙盒 entitlements**，用空/最小 entitlements）→ DMG「重签助手」→ notarytool 公证 → stapler。参考现有 [scripts/package.sh](../../scripts/package.sh)。
5. **真机 E2E 验收**：真账号导入 → 建/导证书 → 选真 IPA → 一键重签 → 装到测试机成功。

**其它已归档的 Minor**（计划 4 顺带看）：`identityStatus` 每次读钥匙串（可缓存进 observable）；输出固定写源 IPA 同目录（源在只读位置如挂载 DMG 会失败，考虑让用户选输出目录或默认下载）；`importAccountConfig`/`deleteAccount` 直接测试较薄。

## 台账
`.superpowers/sdd/progress.md`（gitignored）记录每个任务的提交范围、审查结论、遗留项。建议下次从 `superpowers:brainstorming`（UI 细节）或直接 `writing-plans`（spec 已够细）起手。
