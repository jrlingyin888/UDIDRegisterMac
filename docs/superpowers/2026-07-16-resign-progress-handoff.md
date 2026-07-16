# 重签功能 —— 进度与交接（handoff）

- 日期：2026-07-16
- 分支：`feature/resign-adhoc`（**未合并、未推送**；从 `main` @ `17b5ff9` 分出）
- 当前 HEAD：`46cc5e2`，`swift test` = **77/77 全绿**
- 状态：两个库层完成并测试通过；ReSignApp UI 尚未开始（下次会话继续）

## 背景（一句话）

管理员往苹果账号加测试机 UDID 后，为了给新设备装 IPA 要手动去后台重打包描述文件再重签。**真相：证书加设备不用换、苹果也没有你的 p12；每次真正变的只有 Ad Hoc 描述文件。** 目标是做一个 app 内一键重签：自动用同一套 `.p8` 刷新「含全部设备的最新 Ad Hoc 描述文件」，配合本机 app 创建的证书对 IPA 重签，直接产出可安装 IPA。

设计详见 [specs/2026-07-16-udid-resign-adhoc-design.md](specs/2026-07-16-udid-resign-adhoc-design.md)。

## 已锁定的关键决策

- 全流程 **app 内一键重签**；**Ad Hoc**（iOS Distribution 证书 + 内嵌全部设备的 Ad Hoc 描述文件）。
- **app 帮忙创建证书**（本机生成密钥对 + CSR + 拉证书；不生成/不持久化私钥于磁盘）。
- **同一仓库、独立不沙盒的 `ReSignApp`**，复用/扩展 `UDIDRegisterKit`；现有注册 app 基本不动（仅账号共享时加 entitlements）。
- v1 **不改 bundle ID**；改写 / Development / OTA / 自动开通能力 → 以后。
- 账号共享（App Group + 共享钥匙串组）**延后到 ReSignApp bring-up**（此前它没有消费方、且两 app 未就绪无法端到端验证）。

## 已完成（两个库层，均在本分支）

### 1. `UDIDRegisterKit` 签名 API（原 Plan 1）
计划 [plans/2026-07-16-resign-plan1-kit-signing-api.md](plans/2026-07-16-resign-plan1-kit-signing-api.md) · 59 测试
- `DER`（极简 ASN.1 编码器）、`CSRBuilder` + `SigningKeyPair`（RSA-2048 + 手写 PKCS#10 CSR，**openssl 验签通过**）。
- `ASCClient+Signing`：`findOrCreateBundleId`、`listCertificates`/`createCertificate`、`listProfiles`/`deleteProfile`/`createAdHocProfile`/**`refreshAdHocProfile`**（删旧建新、自动带上全部设备）。
- 模型 `BundleIdInfo`/`CertificateInfo`/`ProfileInfo`（Sendable）；创建接口在返回内容为空时报错、请求体/查询串有断言。

### 2. `ReSignKit` 重签引擎（构建顺序上的第 2 步）
计划 [plans/2026-07-16-resign-plan2-resignkit-engine.md](plans/2026-07-16-resign-plan2-resignkit-engine.md) · +18 测试（真实 codesign 端到端）
- `Subprocess`（并发读管道、无死锁）、`ProvisioningProfile`（`security cms -D` 解析 + 抽 entitlements）、`AppBundle`（由内向外签名顺序枚举）、`CodesignInvocation`（argv）、`TemporaryKeychainIdentity`、`AppResigner`、`IPAResigner`（ditto 解包→重签→重打包）。
- **风险已消除**：app 创建的身份可 codesign **无密码弹窗** —— 关键是用 **SHA-1 指纹**签名 + `set-key-partition-list`，**绝不调用 `security add-trusted-cert`**（它改证书信任设置会弹授权框）。临时钥匙串用完清理、有登录钥匙串守卫（绝不清空用户搜索域）、私钥落盘窗口最小化（0700 + 抹零）。
- **推荐入口是 profile-first**：`AppResigner.resign(appDir:identity:mobileprovisionData:)` / `IPAResigner.resign(ipaURL:outputURL:identity:mobileprovisionData:)`——entitlements 从描述文件抽取，绝不越权。
- **v1 明确限制**：含 `.appex` / `Watch` / `AppClips` 的 app 会**明确报错** `unsupportedNestedBundle`（不静默错签）；多子 bundle 各自描述文件留到 ReSignApp 计划。

> ⚠️ **给测试机安装的教训**：这些集成测试会跑真实 `codesign`/`security`，创建/删除临时钥匙串、临时把临时钥匙串加入用户搜索域。跑之前提醒用户；**永不** `add-trusted-cert`（会弹「证书信任设置」密码框）。

## 下一步：ReSignApp（下次会话写计划 + 实现）

一个不沙盒的 SwiftUI app，串起：**选账号 → 建/选发布证书（`SigningKeyPair`+`createCertificate`，可选导出 p12）→ 选 IPA → 读其 bundleId、`findOrCreateBundleId` → `refreshAdHocProfile` 带账号下全部设备 → `IPAResigner.resign(...mobileprovisionData:)` → 产出 IPA + Finder 显示**。需要一并做：
1. **账号共享**：现有沙盒注册 app 与新不沙盒 app 通过 **App Group**（`accounts.json` 放共享容器）+ **共享 keychain-access-group**（`.p8`）共享账号；给现有 app 加两项 entitlements + 一次性迁移。
2. **打包**：`scripts/package.sh` 扩展为可分别 Developer ID 签名 + 公证两个 app（ReSignApp 不沙盒但仍走公证）。
3. UI 上暴露 v1 限制（含扩展/Watch 的 app 报错）与「能力不匹配」的清晰报错。

建议下次会话从 `superpowers:brainstorming`/`writing-plans` 起手，把 ReSignApp 拆成一个计划再执行。

## 进度台账
`.superpowers/sdd/progress.md`（gitignored）记录了每个任务的提交范围、审查结论与遗留 Minor。
