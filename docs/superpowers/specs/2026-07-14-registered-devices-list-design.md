# 已登记设备列表 + 结果区管理 —— 设计

- 日期：2026-07-14
- 分支：feature/mac-app-impl
- 状态：设计已通过

## 目标

同一个主界面上的两处小改进：

1. **已登记设备列表**：在「已用 N / 100 台」额度文案**左边**加图标按钮，点击弹出 popover，展示当前账号下所有已登记设备及状态。
2. **结果区管理**：给「结果」区加清除按钮，并在切换/删除当前账号时自动清空结果。

两者互补：**结果 = 最近一次注册动作的临时输出**（可手动清、切/删账号自动清、注册后保留）；**已登记设备列表 = 该账号当前登记的持久状态**（按账号、自动刷新、可手动刷新）。

## 关键决定（已与用户确认）

- 弹出方式：**Popover 气泡**（轻量、点外面自动关）。
- 每行内容：**设备名 + 状态徽章**（不显示 UDID / 型号 / 日期）。
- Popover 内提供**手动刷新**按钮（设备会从「处理中」变「已可用」，需要能拉最新）。

## 设计

### 数据层（零额外请求）
`AppModel.refreshQuota()` 现已调用 `client.listDevices` 拿到完整 `[DeviceRow]`，但只用了 `.count`。改为把整份列表存进新字段 `var devices: [DeviceRow] = []`，沿用现有账号 race-guard（`if selectedID == a.id`）：
- 成功：`quotaText = "已用 N / 100 台"`，`devices = rows`。
- 失败：`quotaText = "额度获取失败"`，`devices = []`。
- 无账号：两者都清空。

`refreshQuota()` 本就在「启动 / 切账号 / 注册后」触发，因此 `devices` 始终与额度同步，无需新增网络调用。Popover 里的「刷新」按钮复用 `refreshQuota()`。

### 状态徽章
在 `StatusText.swift` 增加精简版 `statusBadge(_ s: DeviceStatus) -> String`：
- `.enabled` → `✅ 已可用`
- `.processing` → `⏳ 处理中`
- `.disabled` → `🚫 已禁用`
- `.unknown` → `ℹ️ 未知`

（现有 `statusText` 太长，不适合列表行。）

### UI
- 新增 `Sources/UDIDRegisterApp/DeviceListView.swift`：popover 内容。顶部标题「已登记设备（N）」+ 刷新按钮；下面可滚动列表，每行「设备名 ···· 状态徽章」；空态显示「暂无已登记设备」。固定宽 320，列表区最高约 360、超出滚动。
- `RootView.swift`：顶部 HStack 里、额度文案左侧加一个 SF Symbol 图标按钮（`list.bullet.rectangle`），`.popover(isPresented:)` 弹出 `DeviceListView`。按钮仅在 `!quotaText.isEmpty`（即已选账号）时显示。

### 结果区管理（RegisterView）
- **清除按钮**：把「结果」标题行改为 HStack —— 左标题 +（`Spacer`）右上角清除图标按钮（`trash`），点击 `model.results = []`。整块本就仅在 `!results.isEmpty` 时显示。
- **切/删账号自动清空**：在 `RootView` 已有的 `.onChange(of: model.selectedID)` 里增加 `model.results = []`。
  - 覆盖：用户切换账号 → selectedID 变 → 清空 ✓；删除当前选中账号 → reload 使 selectedID 变 → 清空 ✓；新增账号自动选中 → 清空（无害）✓。
  - 删除**非当前**账号时 selectedID 不变、结果保留（仍在看同一账号，合理）。
  - 注册完成不改 selectedID，结果保留（符合预期）。

## 非目标
- 设备列表不显示 UDID / 型号 / 添加日期。
- 不做搜索/筛选/排序（保持 Apple 返回顺序）。
- 不做删除/停用设备操作（Apple API 也不支持删除）。
- 结果不做按账号分别持久化（已被「已登记设备列表」覆盖）。

## 影响面
- 改：`AppModel.swift`（devices 字段 + refreshQuota）、`StatusText.swift`（statusBadge）、`RootView.swift`（图标按钮 + popover + onChange 清空结果）、`RegisterView.swift`（结果标题行 + 清除按钮）。
- 新增：`DeviceListView.swift`。

## 验证
改动全在 App/UI 层（与现有 `StatusText`/`RootView` 一致，本就无单测）。`swift build` 通过 + 手动验证：点图标弹出列表、状态徽章正确、刷新可用、空态正常。
