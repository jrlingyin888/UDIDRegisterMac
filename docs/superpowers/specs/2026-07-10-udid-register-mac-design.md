# UDID 注册助手（macOS 原生 app）— 设计文档

- **日期**：2026-07-10
- **状态**：已确认，待写实现计划
- **来源**：从 Cloudflare Worker 版 `udid-register`（内部 QA 自助注册工具）演进为可商业化的本地 Mac app

---

## 1. 背景与目标

现有工具 `udid-register` 是一个 Cloudflare Worker：托管一个网页表单，测试同事打开公网 URL、填 UDID + 一次性口令，Worker 签 App Store Connect（ASC）JWT 并 `POST` 到 Apple 注册设备。它依赖本地 `wrangler dev` + `cloudflared` 隧道给出临时公网地址。

本项目把它重做成一个**纯本地的 macOS 原生 app**，用于**商业化售卖**：

- 管理员（客户）在 app 里管理一个或多个苹果开发者账号凭据（`.p8` + Issuer ID + Key ID）。
- 管理员把测试机 UDID **录入 app**（单条或批量），app 用选中的账号**直接调用 ASC API 注册**。
- 每台设备注册后显示**真实状态**（已可用 / 处理中 / 已存在等）。
- 全程**无本地服务器、无隧道、无云后台**；`.p8` 私钥**只存在本机 Keychain**，不出本机。

### 成功标准
1. 能添加/选择多个苹果账号，`.p8` 安全存储，可「测试连接」验证凭据。
2. 能批量录入 UDID 并逐条注册，结果准确反映 Apple 返回（含「已存在」时的真实状态）。
3. 能看到该账号「已用 X / 100 台」额度。
4. 产出经 Developer ID 签名 + 公证的 app，可直接分发/售卖。

---

## 2. 非目标（v1 明确不做，YAGNI）

- 授权 / 激活 / 试用期 / license key（以后再加，且与「零后台」初衷冲突）。
- 自助网页表单、Cloudflare/cloudflared 隧道、任何云端后台。
- 设备删除（Apple API 只能 *禁用* 设备，且仍占用 100 台/年额度直到年度重置，做了也没价值）。
- Windows / 跨平台。
- Mac App Store 上架（作为未来可选项，非 v1）。

---

## 3. 关键决策记录

| 决策 | 选择 | 理由 |
|------|------|------|
| 产品形态 | **本地录入型**（管理员录 UDID，app 直连 Apple） | 零隧道/零后台/零第三方；`.p8` 不出本机，安全且是卖点；不受 `trycloudflare.com` 测试用途/条款/可靠性限制 |
| 技术栈 | **SwiftUI 原生** | 最像正经 Mac 软件、体积小、Keychain/公证顺、CryptoKit 直接签 ES256 |
| 隧道 | **无** | 本地录入不需要手机访问本机；只需 Mac 正常出网调 Apple API |
| v1 授权 | **不做** | 先拿到能用、能卖的产品 |
| 凭据字段 | `.p8` + Issuer ID + **Key ID**；Team ID 可选仅展示 | ASC 注册设备只认前三者，**不用 Team ID**（沿用现有 Worker 行为） |
| 代码仓库 | **新 repo `UDIDRegisterMac`** | Swift 工程与旧 JS Worker 分开；旧 Worker 保持不动 |
| 分发 | Developer ID 签名 + 公证 DMG，**独立分发** | 免 App Store 30% 抽成与审核，dev 工具常规做法 |

---

## 4. 架构总览

单窗口 SwiftUI app，分层：

```
┌────────────────────────── UI (SwiftUI) ──────────────────────────┐
│  账号选择器 + 额度   │  UDID 批量录入   │  注册结果列表            │
│  账号管理 Sheet（增删改 + 测试连接）                              │
└───────────────┬──────────────────────────────────────────────────┘
                │ 调用
┌───────────────▼──────────── Services ────────────────────────────┐
│ AccountStore   账号元数据(本地) + .p8(Keychain) 的增删改查        │
│ KeychainStore  .p8 私钥的安全存取（Security framework）           │
│ ASCJWT         用 CryptoKit 签 ES256 JWT                          │
│ ASCClient      registerDevice / listDevices（URLSession）        │
│ UDIDNormalizer UDID 规范化（沿用 worker.js 规则）                 │
└──────────────────────────────────────────────────────────────────┘
                │ HTTPS（唯一外部依赖）
        api.appstoreconnect.apple.com
```

无常驻进程、无监听端口。app 打开即用，关闭即结束——不存在「服务起停」。

---

## 5. 数据模型

```swift
struct AppleAccount: Identifiable, Codable, Hashable {
    let id: UUID
    var displayName: String     // 例：jgz / 公司A
    var keyID: String           // ASC Key ID，例 QA2MC7L8X7
    var issuerID: String        // Issuer ID（UUID）
    var teamID: String?         // 可选，仅用于展示区分
    // .p8 不在此结构里——存 Keychain，用 id 关联
}

struct DeviceInput: Identifiable {
    let id = UUID()
    var udidRaw: String
    var name: String            // 允许为空 → 用默认名
}

enum RegistrationOutcome {
    case created(status: DeviceStatus)          // 新注册成功（通常 PROCESSING）
    case alreadyExisted(name: String, status: DeviceStatus)  // 409 回查
    case failed(message: String)
}

enum DeviceStatus: String {
    case enabled = "ENABLED"
    case processing = "PROCESSING"
    case disabled = "DISABLED"
    case unknown                    // 其它/未识别；用 DeviceStatus(rawValue:) ?? .unknown 兜底
}

struct DeviceRow {                // ASC GET /v1/devices 的元素
    let id: String
    var name: String
    var udid: String
    var status: DeviceStatus
    var model: String?
    var addedDate: String?
}
```

- **元数据存储**：`[AppleAccount]` 序列化进 `Application Support`（或 `UserDefaults`），非敏感。
- **`.p8` 存储**：Keychain generic password，account = `AppleAccount.id.uuidString`，service = bundle id。

---

## 6. 模块详解

### 6.1 账号管理
- 列表展示已存账号；支持添加、编辑、删除。
- **添加**：`fileImporter` / `NSOpenPanel` 选 `.p8`；文本框填 Key ID、Issuer ID、显示名、（可选）Team ID。
- **测试连接**：签一个 JWT + 调 `GET /v1/devices?limit=1`；200 视为凭据有效，否则展示 Apple 的错误。用于添加/编辑时即时校验。
- **删除**：同时清掉 Keychain 里的 `.p8`。
- 顶部选择器切换「当前账号」；切换后刷新额度与后续注册目标。

### 6.2 UDID 录入
- 一个多行文本框，每行一条：`UDID` 或 `UDID,名称`（逗号后为设备名，可留空）。
- 解析：按行 split、trim、忽略空行；名称缺省时用默认名（⚙️ 默认 `Device-<短UDID>`，可后续改）。
- 每行 UDID 经 `UDIDNormalizer` 规范化；非法行在结果里单独标红，不阻断其它行。

### 6.3 注册 + 状态（核心，逻辑照搬已验证的 Worker 行为）
对每条依次（或并发，见错误处理）调用 `ASCClient.registerDevice`：
- `POST /v1/devices`，body：`{data:{type:"devices",attributes:{name,udid,platform:"IOS"}}}`
- **201**：读 `data.attributes.status` → `.created(status)`。
- **409（已存在）**：调 `listDevices` 按 UDID 回查该设备，返回 `.alreadyExisted(name, status)`；回查不到则 `.failed(Apple 原始 detail)`。
- **其它**：`.failed(errors[0].detail 或状态码)`。

状态文案（与现有 Worker 前端一致）：
- `ENABLED` → ✅ 已可用 — 可直接用于真机调试/打包
- `PROCESSING` → ⏳ 处理中 — 苹果正在处理，**可能需 24~72 小时**才可供开发使用
- `DISABLED` → 🚫 已禁用 — 仍占用 100 台/年额度
- 其它 → 原样展示状态字符串

### 6.4 额度视图
- 选中账号后 `listDevices` 一次，显示「已用 `count` / 100 台」。
- 注册完成后刷新。提醒管理员剩余额度（Apple 硬限制，不可中途删）。

---

## 7. 关键技术实现

### 7.1 用 CryptoKit 签 ES256 JWT
```swift
// .p8 是 PKCS#8（"BEGIN PRIVATE KEY"）；CryptoKit 直接吃 PEM
let key = try P256.Signing.PrivateKey(pemRepresentation: p8Pem)   // macOS 11+
let now = Int(Date().timeIntervalSince1970)
let header  = ["alg":"ES256","kid":keyID,"typ":"JWT"]
let payload = ["iss":issuerID, "iat":now - 30,      // iat 回拨 30s：避免本机时钟略快被判未来 token → 401
               "exp":now + 1100, "aud":"appstoreconnect-v1"] as [String:Any]
let signingInput = b64url(header) + "." + b64url(payload)
let sig = try key.signature(for: Data(signingInput.utf8))
let jwt = signingInput + "." + base64url(sig.rawRepresentation)   // rawRepresentation = 64B r||s，正是 ES256 所需
```
`iat - 30` 的坑与现有 [worker.js](../../../../udid-register/src/worker.js) 一致，务必保留。

### 7.2 ASC API 调用
- `ASCClient.registerDevice(account:name:udid:) async throws -> RegistrationOutcome`
- `ASCClient.listDevices(account:) async throws -> [DeviceRow]`（`GET /v1/devices?limit=200`，账号上限 100 台一页足够；用于 409 回查与额度）
- 每次调用现签 JWT（`exp` 短），无需缓存。

### 7.3 UDID 规范化（沿用 worker.js:103）
- 全小写后：`^[0-9a-f]{8}-[0-9a-f]{16}$` → 转大写返回；`^[0-9a-f]{40}$` → 原样（小写）返回；否则非法。
- 与 Apple 存储习惯一致（现代机大写带连字符、旧机小写 40 位）。

### 7.4 Keychain
- 存：`kSecClassGenericPassword`，`kSecAttrService = bundleID`，`kSecAttrAccount = account.id`，`kSecValueData = .p8 UTF8`。
- 可访问性 `kSecAttrAccessibleWhenUnlocked`。删除账号时一并删除。

---

## 8. 安全

- `.p8` 私钥仅存 Keychain；**绝不写磁盘明文、绝不进日志**。
- 导入后不再需要原始 `.p8` 文件本身。
- 网络仅出向 `api.appstoreconnect.apple.com`（HTTPS）。
- 沙盒 entitlements（如启用沙盒）：`com.apple.security.files.user-selected.read-only`（选 .p8）、`com.apple.security.network.client`（调 API）、Keychain 访问组。独立分发可不强制沙盒，但建议开启。

---

## 9. 错误处理

- **单条隔离**：批量注册中某条失败/非法不影响其它条；每条各自展示结果。
- ⚙️ **串行注册**（v1）：逐条顺序调用，简单、避免 Apple 侧速率问题；结果实时逐行更新。（并发留作以后优化。）
- **网络错误**：整体给出可读提示（如「无法连接 Apple，请检查网络」），不崩溃。
- **凭据错误**（JWT 401 / key 解析失败）：在「测试连接」和注册时都给明确提示。
- **409 回查失败**：降级为展示 Apple 原始「already exists」文案。

---

## 10. 测试策略

对标现有 `verify.mjs` 的思路，用 XCTest：

- **UDIDNormalizer**：40 位十六进制、8-16 带连字符、大小写、非法输入等用例。
- **ASCJWT**：用测试用 P-256 私钥签名后本地验签；校验 header/claims、`iat` 回拨 30s、签名为 64 字节。
- **ASCClient**：用自定义 `URLProtocol` mock Apple 响应：
  - 201 → `.created(status)`
  - 409 + 列表含该 UDID → `.alreadyExisted(name,status)`
  - 409 + 列表查不到 → `.failed`
  - 口令/凭据类错误路径
- **手动验收**：用真实 jgz 账号「测试连接」+ 真注册一台，核对状态与后台一致。

---

## 11. 分发

- **Developer ID Application** 签名 + **公证（notarytool）** + stapled DMG，独立分发（官网/网盘售卖）。
- 需要用到开发者账号做签名/公证证书。
- Mac App Store 上架列为未来可选（需沙盒合规 + 审核）。

---

## 12. 代码组织（新 repo `UDIDRegisterMac`）

```
UDIDRegisterMac/
├── docs/superpowers/specs/2026-07-10-udid-register-mac-design.md   （本文件）
├── UDIDRegisterMac.xcodeproj
├── UDIDRegisterMac/
│   ├── App.swift                 应用入口
│   ├── Models/                   AppleAccount / DeviceInput / DeviceStatus …
│   ├── Services/                 KeychainStore / ASCJWT / ASCClient / UDIDNormalizer / AccountStore
│   ├── Views/                    RootView / AccountPicker / AccountManagerSheet / RegisterView / ResultList
│   └── Resources/                Assets、entitlements、Info.plist
└── UDIDRegisterMacTests/         XCTest（上一节）
```

现有 `udid-register`（Worker）**保持不动**，仅作为逻辑参考来源。

---

## 13. 开放问题 / 未来

- 授权/激活（v2）：若做，倾向轻量本地校验 + 你侧一个极简发 key 服务，避免重后台。
- 自助网页模式（v2 可选）：作为「附加模式」内置隧道，但需正视 `trycloudflare.com` 商用限制。
- 并发注册、导入 CSV/文件、注册历史记录/导出，均为增强项，非 v1。
