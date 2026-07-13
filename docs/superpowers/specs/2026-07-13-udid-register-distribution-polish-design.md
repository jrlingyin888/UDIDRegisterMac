# UDID 注册助手 — 分发打磨设计（Distribution Polish）

- 日期：2026-07-13
- 分支：feature/mac-app-impl
- 状态：设计已通过（待 spec 复核）
- 关联：接续 [2026-07-10 UDID 注册助手设计](./2026-07-10-udid-register-mac-design.md)

## 背景与目标

现有 app 功能已完整：多账号、批量注册、额度显示、Keychain 存储 `.p8`、签名 + 公证 + DMG 打包脚本俱全，逻辑层有 ~19 个单测。现在要把它发给**同事自助注册测试设备**。

已确定的前提（本轮不再更改）：

- **分发/信任模型**：保持本地方案，凭据（Key ID / Issuer ID / `.p8`）**手动下发到每台同事机器**，存本机 Keychain。**不引入后端/瘦客户端**。
- **同事画像**：混合人群（既有技术型也有非技术型）。因此首次配置**两种入口都要**：保留手填表单，同时提供「一键配置文件」导入。

本轮目标：把 app 打磨到可安心分发，并显著降低同事首次配置门槛。

## 范围（方案 B）

1. 修 bundle-id 占位符 → `com.pangu.UDIDRegisterMac`，并做成单一来源。
2. App 图标 + 仓库内真实 Info.plist。
3. 一键配置文件 `.udidconfig` 的导出/导入。
4. 友好中文报错映射。
5. 面向同事的中文使用说明文档。
6. 删除账号二次确认。

## 非目标（Non-goals）

- 后端 / 瘦客户端（已明确否决）。
- 账号编辑 UI、批量注册进度条、自动更新、License/激活——留待后续。
- 真机 Keychain 单测（保持现状，仅 InMemory 覆盖）。
- 其它 Apple 平台（`platform` 仍固定 `IOS`）。
- `.udidconfig` 双击文件关联（列为可选加分项，不阻塞本轮）。

## 详细设计

### 1. Bundle ID 单一来源

- **定值**：`com.pangu.UDIDRegisterMac`
- **现状**：同一个值出现在两处且必须一致，无任何防呆：
  - `Sources/UDIDRegisterKit/SecretStore.swift:22` — Keychain `service`
  - `scripts/package.sh:19` — Info.plist `CFBundleIdentifier`
  - 若两处不一致，打包版里同事导入的凭据将读不出来（Keychain service 对不上）。
- **方案**：
  - 新增 `Sources/UDIDRegisterKit/AppIdentifiers.swift`，定义 `enum AppIdentifiers { static let bundleID = "com.pangu.UDIDRegisterMac" }`，作为**唯一真值来源**。
  - `KeychainSecretStore` 的默认 `service` 改用 `AppIdentifiers.bundleID`。
  - `package.sh` 顶部不再硬编码 bundle-id，而是用 `grep`/`sed` 从 `AppIdentifiers.swift` 抽出该常量值，再用 `plutil`/`PlistBuddy` 写进复制出来的 Info.plist 的 `CFBundleIdentifier`。这样 Swift 常量成为脚本侧也共享的单一来源。
  - 若解析失败，脚本应报错退出（不允许 fallback 到空值），避免生成 bundle-id 错误的包。

### 2. App 图标 + 仓库内 Info.plist

- **Info.plist 落地**：把现在 `package.sh` 用 heredoc 现拼的 plist 抽成仓库内真实文件 `Resources/Info.plist`，包含：`CFBundleName`（"UDID 注册助手"）、`CFBundleIdentifier`（由脚本按第 1 点写入）、`CFBundleShortVersionString`、`CFBundleVersion`、`LSMinimumSystemVersion` = 14.0、`CFBundleIconFile` = `AppIcon`、`CFBundlePackageType` = APPL、`LSApplicationCategoryType`（开发工具类）。`package.sh` 改为复制该文件而非内联生成。版本号、名称、图标从此在一处维护。
- **图标**：
  - 设计意象：圆角方形背景（蓝→紫渐变），中间一个手机/设备轮廓叠加一个绿色对勾，表达"测试设备已注册"。风格简洁、扁平，符合 macOS 图标观感。
  - 生成方式：提供 `scripts/make-icon.swift`（AppKit / CoreGraphics 绘制 1024×1024 源图 → 输出 `.iconset` 各标准尺寸 16~1024（含 @2x）→ `iconutil -c icns` → `Resources/AppIcon.icns`）。产物 `AppIcon.icns` 一次性生成并入库，避免每次打包都依赖工具链。
  - `package.sh` 把 `AppIcon.icns` 拷进 `<App>.app/Contents/Resources/`。
  - 以后要换真 logo，只需替换源图重跑脚本，或直接替换 `AppIcon.icns`。

### 3. 一键配置文件 `.udidconfig`（核心）

- **文件格式**：UTF-8 JSON。
  ```json
  {
    "schemaVersion": 1,
    "displayName": "公司主账号",
    "keyID": "XXXXXXXXXX",
    "issuerID": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "teamID": "XXXXXXXXXX",
    "p8PEM": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n"
  }
  ```
- **Kit 层（可测，纯逻辑）**：
  - 新增 `Sources/UDIDRegisterKit/AccountConfig.swift`：`struct AccountConfig: Codable`（上述字段）+ `enum AccountConfigCodec { static func encode(...) throws -> Data; static func decode(_:) throws -> AccountConfig }`。
  - decode 校验：`schemaVersion` 必须受支持；缺字段 / 非法 JSON / PEM 明显不合法 → 抛带中文描述的错误。
  - 单测覆盖：正常 round-trip、缺字段、版本不匹配、非法 JSON、空 PEM。
- **导出（管理员端）**：
  - `AccountManagerView` 对每个已存在账号加「导出配置…」入口。
  - `AppModel.exportConfig(for:)`：读账号元数据 + 从 `SecretStore` 取出 `p8PEM` → 组装 `AccountConfig` → `AccountConfigCodec.encode`。
  - UI 用 `fileExporter`/`NSSavePanel` 保存为 `<displayName>.udidconfig`。
  - 导出时提示："此文件包含私钥，请通过安全渠道发给同事，用完可删除。"
- **导入（同事端）**：
  - `AccountManagerView` 加「导入配置文件…」按钮，`fileImporter`。UTType 优先用自定义类型（见下），若沙盒识别有坑则退化为允许 `.json` / 全部文件 + 后缀 `.udidconfig` 过滤。
  - `AppModel.importConfig(from:)`：安全域访问读文件 → `AccountConfigCodec.decode` → **复用现有 `addAccount` 流程**（联网 `listDevices` 校验 → 写 Keychain → 建账号 → 失败回滚）→ 成功后自动选中该账号并刷新额度。
  - 失败：解析失败 / 校验失败 → 走第 4 点的友好中文 banner。
  - **复用了绝大部分现有代码，新增面很小。**
- **UTType（可选加分，不阻塞）**：可定义 `com.pangu.UDIDRegisterMac.udidconfig`（conforms to `public.json`），在 Info.plist 声明 `UTExportedTypeDeclarations`；双击 `.udidconfig` 直接打开 app 的关联（`CFBundleDocumentTypes` + open-file 处理）列为后续加分项。本轮只做**按钮导入/导出**即可。

### 4. 友好中文报错映射

- **Kit 层**：
  - 给 `ASCError`、`ASCJWTError` 补 `LocalizedError` 的中文 `errorDescription`。
  - 新增集中映射 `enum UserFacingMessage { static func from(_ error: Error) -> String }`，常见情况：
    - 401 / 403 → "凭据无效或已过期，请检查 Key ID / Issuer ID / .p8 是否正确"
    - `URLError`（网络类）→ "网络连接失败，请检查网络后重试"
    - `ASCJWTError.invalidPrivateKey` → "这个 .p8 文件无法识别，请确认是从 App Store Connect 下载的原始 .p8 文件"
    - 其它带 Apple `detail` 的 `ASCError` → 保留原文，加中文前缀"注册失败："
- **接入**：`AppModel` 的 banner 文案与 `row.failed` 文案统一走 `UserFacingMessage.from`。
- 单测：各类错误 → 期望中文串。

### 5. 面向同事的使用说明

- 新增 `docs/同事使用说明.md`（中文，面向同事，非开发者）。内容：
  - 拿到 `.udidconfig` → 打开 app → 「导入配置文件…」→ 选中文件（一次性配好）。
  - 粘贴 UDID：一行一个，可写 `UDID,备注名`。
  - 点「注册」，看结果：✅ 新注册 / ℹ️ 已存在 / ❌ 失败（含格式不正确）。
  - 额度含义：100 台/年；设备停用仍占额度，直到 Apple 年度重置。
  - 常见问题：导入失败怎么办、UDID 从哪拿、注册后多久生效（24–72h）。
- README 保持开发者向；在 README 增加"分发 / 给同事使用"小节，链到该文档与打包脚本说明。

### 6. 删除账号二次确认

- `AccountManagerView` 删除按钮改为先弹确认 `alert`："确定删除账号 X？此操作会移除本机保存的凭据。"确认后才调用现有删除逻辑（Keychain + 账号 JSON 同步删除，已有回滚保障）。

## 影响面

- **新增文件**：
  - `Sources/UDIDRegisterKit/AppIdentifiers.swift`
  - `Sources/UDIDRegisterKit/AccountConfig.swift`（含 `AccountConfigCodec`）
  - `Sources/UDIDRegisterKit/UserFacingMessage.swift`
  - 对应测试：`Tests/UDIDRegisterKitTests/AccountConfigTests.swift`、`UserFacingMessageTests.swift`
  - `Resources/Info.plist`、`Resources/AppIcon.icns`
  - `scripts/make-icon.swift`
  - `docs/同事使用说明.md`
- **改动文件**：
  - `Sources/UDIDRegisterKit/SecretStore.swift`（service 用常量）
  - `scripts/package.sh`（复制 Info.plist + 图标；bundle-id 从 Swift 常量抽取写入 plist）
  - `Sources/UDIDRegisterApp/AccountManagerView.swift`（导入/导出/删除确认入口）
  - `Sources/UDIDRegisterApp/AppModel.swift`（`exportConfig`/`importConfig` + 错误映射接入）
  - `Sources/UDIDRegisterApp/StatusText.swift` / `RootView.swift`（错误文案接入，视需要）
  - `README.md`

## 验证计划

- `swift test` 全绿（新增单测：AccountConfig 编解码、UserFacingMessage 映射）。
- 手动端到端：
  1. 用管理员账号「导出配置…」得到 `.udidconfig`。
  2. 删除该账号（模拟"干净的同事机器"）→「导入配置文件…」导入该文件 → 应自动建账号、自动选中、显示额度。
  3. 批量粘贴 2 个 UDID（一个合法、一个乱写）注册 → 合法者成功/已存在，乱写者显示"UDID 格式不正确"。
  4. 断网重试 → 出中文网络错误提示。
  5. 跑 `scripts/package.sh` → 确认 `.app` 有图标、`CFBundleIdentifier` 正确、公证通过、可正常打开。
  6. **打包版 Keychain 一致性**：在打包版里导入配置并重启 app，凭据仍可读（验证 bundle-id 单源生效）。

## 风险与权衡

- **`.udidconfig` 明文含私钥**：属既定的凭据下发模型的固有代价；靠文档提示"安全渠道传输 + 用后删除"缓解。不做额外加密（会引入密码分发问题，得不偿失）。
- **自定义 UTType 在沙盒 `fileImporter` 的兼容性**：若识别有坑，退化为允许 `.json`/全部文件 + 后缀校验。
- **图标生成依赖本机工具链**（`iconutil`/AppKit）：靠"一次性生成入库"规避每次打包的依赖。
