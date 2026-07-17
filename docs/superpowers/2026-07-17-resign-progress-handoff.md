# 重签功能 —— 进度与交接（handoff，2026-07-17）

> 取代 [2026-07-16-resign-progress-handoff.md](2026-07-16-resign-progress-handoff.md)（那份是 ReSignKit 完成时的状态）。

- 分支：`feature/resign-adhoc`（**未合并、未推送**；从 `main` @ `17b5ff9` 分出）
- 当前 HEAD：`19a306f`，`swift test` = **98/98 全绿**
- 状态：**计划 4（UI + 打包）已完成** —— 库层 + ReSignApp 核心逻辑 + UI + 打包脚本全部done。详见下方「计划 4（UI + 打包）完成」一节。剩两步交用户执行：公证打包、真机 E2E 验收。以下「已完成」「下一步：计划 4」两节为计划 4 开始前的原始记录，保留供追溯，不再代表当前状态。

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

---

## 计划 4（UI + 打包）完成（2026-07-17，收尾）

计划 4（[plans/2026-07-17-resignapp-plan4-ui-packaging.md](plans/2026-07-17-resignapp-plan4-ui-packaging.md)）全部 9 个任务已完成，分支 HEAD = `19a306f`。ReSignApp 三层（UDIDRegisterKit 签名 API / ReSignKit 引擎 / ReSignAppCore+UI）现已**全部**做完并本地验证通过。

### 本次验证结果

- `swift build`：**成功**（全部 3 个可执行 target：UDIDRegisterApp、ReSignApp，及全部库/测试 target 编译干净）。
- `swift test`：**98/98 全绿**（Swift Testing 额外 0 个测试，无失败）。
- 启动冒烟（`swift run ReSignApp` 等价操作）：编译产物直接启动，进程稳定驻留（`ps` 显示 `S`/`N` 睡眠态、CPU 0%），运行数秒后无崩溃、无 stdout/stderr 报错、`~/Library/Logs/DiagnosticReports/` 无新崩溃日志。**但**本次 agent 会话是无 Aqua/无辅助功能权限的沙盒环境——`osascript`/System Events 查窗口会挂起等一个无法应答的权限弹窗（8 秒后手动 kill），因此**无法在本次会话里用截图/窗口计数确认「重签助手」窗口真的可见**。这与 Task 6 记录的环境局限一致（见下方「验收注意事项」）。

### 计划 4 交付内容清单

- **exportP12**：`SigningIdentityManager`/`ReSignModel` 新增导出——openssl 把已存的私钥+证书重新组装成 p12（stdin 传密码，不经 argv），供用户留底；含私钥字节级 round-trip 测试、无身份/空密码等守卫路径测试。
- **输出路径**：`resolveOutputURL` —— 优先写回源 IPA 同目录，源目录只读（如挂载的 DMG）时自动回退到 `~/Downloads`。
- **`TemporaryKeychainIdentity` 生产证书泄漏修复**（原计划 3 遗留的 MUST-FIX）：init 内在 `security import` **之前**先做一次登录钥匙串快照（按叶证书 SHA-1 判断是否已存在，字段默认 `true` 以防初始化中途在快照前抛出而误删用户自有证书）；cleanup 里**仅当**导入前不存在时才 `delete-certificate -Z` 删一次，只删我们这次导入新增的那份副本，绝不动用户自己原有的证书。已提交回归测试 `testCleanupNeverDeletesPreexistingLoginCert`（预置证书到登录钥匙串 → 验证存活 → defer 清理）+ `testCleanupRemovesLeakedCertFromLoginKeychain`。
- **`ReSignModel.live()`**：与注册 app 完全隔离验证——账号库路径 `~/Library/Application Support/ReSignMac/accounts.json`（非 UDIDRegisterMac）、Keychain service `com.pangu.ReSignMac`（签名身份额外用 `com.pangu.ReSignMac.signing`），有测试正向 pin 路径 + 反向断言不含 `/UDIDRegisterMac/`。
- **SwiftUI `@main` + 完整 `ReSignRootView`**：`AppDelegate` 显式 `setActivationPolicy(.regular)`（SPM 可执行体需要，否则无 Dock 图标/前台窗口）；RootView 含账号 Picker + 管理入口、签名身份徽章 + 自动创建/导入 p12/导出 p12 三个按钮、IPA 拖入+选择、一键重签 + 进度日志 + 「在 Finder 中显示」；`AccountsSheet.swift`、`PasswordSheet.swift` 两个 sheet。
- **专属图标**：`make-icon.swift` 参数化支持 `resign` 变体 → 独立青绿色调图标 `Resources/ReSignAppIcon.icns`（~999KB，已提交），与注册 app 原有蓝紫图标 `Resources/AppIcon.icns` 字节级验证未受影响（两端 git diff 为空）。
- **打包骨架**：`Resources/ReSignApp-Info.plist`（显示名「重签助手」、bundle id `com.pangu.ReSignMac`、可执行名 `ReSignApp`、图标 `ReSignAppIcon`）+ `Resources/ReSignApp.entitlements`（空 `<dict/>`，**不带 App Sandbox**，因为重签需要读写任意用户选择的 IPA/keychain，与注册 app 的沙盒策略刻意不同）+ `scripts/package-resign.sh`（独立于现有 `scripts/package.sh`，产出独立卷标「重签助手」的 `dist/ReSignMac.dmg`）。本地已核对：`bash -n` 语法检查、`plutil` lint Info.plist + entitlements、bundle-id 提取正确、`swift build -c release --product ReSignApp` 编译通过。

### 待用户执行的两步（我这边做不了，需要用户的签名凭据/真机）

1. **公证打包**：
   ```bash
   export DEV_ID_APP="Developer ID Application: … (TEAMID)"
   export NOTARY_PROFILE=<profile>
   scripts/package-resign.sh
   ```
   产出 `dist/ReSignMac.dmg`。
2. **真机 E2E 验收**：导入真实账号配置文件 → 自动创建证书或导入已有 p12 → 选一个真实 IPA → 点「一键重签」→ 用 Apple Configurator 把产出的 IPA 装到测试机上，确认能装、能跑。

### 验收注意事项（请在真机 E2E 时一并确认）

- **(a) 登录钥匙串泄漏修复未能在本环境复现真实泄漏**：本次及此前所有验证会话都是无 Aqua 的无头构建环境，`security import` 往登录钥匙串留证书副本这个 OS 级行为在这种环境下没有被复现（详见 plan 4 Task 3 记录）。修复本身已经过代码走查确认正确，并有一条「预先存在的证书永不被删」的回归测试兜底；但**真实效果**（即：用真实发行证书跑一次重签后，登录钥匙串里不多出一份重复证书）建议在真机 E2E 时顺手确认一次（重签前后 `security find-certificate -a -c "<证书名>" login.keychain-db` 各跑一次，数量应不变）。
- **(b) 完整 RootView 的 GUI 窗口建议在真实交互式会话中肉眼复核一次**：Task 6 记录过一次无头启动冒烟显示「0 个窗口」，但审查确认这是当时环境/会话问题（截图显示当时**所有**进程的窗口都拿不到，不只是本 app），而非代码缺陷；本次 Task 9 复核同样受限于无 Aqua/无辅助功能权限的沙盒会话，无法用 System Events/截图确认窗口渲染，只能确认进程本身启动稳定、不崩溃。建议用户在自己的正常图形界面下手动 `swift run ReSignApp` 一次，确认窗口标题「重签助手」正常弹出，账号/身份/IPA/重签/日志各区可点、可拖拽。
