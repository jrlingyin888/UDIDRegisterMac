# feature/mac-app-impl — 分支收尾说明

- 日期：2026-07-14
- 分支：feature/mac-app-impl → 合并入 main
- 质量门：`swift build` 通过；`swift test` 35/35 绿；逐任务子代理评审 + opus 全分支评审，均无 Critical/Important。

## 分支交付内容

原生 macOS 应用「UDID 注册助手」——本地方案，把测试设备 UDID 注册进苹果开发者账号（App Store Connect API），凭据存本机 Keychain，无后端。分三轮完成：

### 第 1 轮：原始 app（plan 2026-07-10，10 任务）
两层结构：可测的 `UDIDRegisterKit`（JWT/HTTP/ASC/Keychain/账号存储）+ 薄 SwiftUI 壳。多账号、批量注册、额度显示、Keychain 存 .p8、签名+公证+DMG 打包。

### 第 2 轮：分发打磨（spec/plan 2026-07-13，8 任务）
- bundle-id 单一来源（`AppIdentifiers.bundleID = com.pangu.UDIDRegisterMac`）→ Keychain service 与打包 Info.plist 永不漂移。
- `.udidconfig` 一键配置文件（导出/导入，复用 addAccount），友好中文报错映射。
- App 图标、仓库内 Info.plist、打包脚本单源化、读写 entitlement。
- 同事使用说明 + README 分发小节。

### 第 3 轮：UI/打包迭代（2026-07-14）
- **修复**：账号管理里两个 `.fileImporter` 叠在同一 View 导致「选择 .p8 文件」按钮无反应 → 合并为单个、用枚举区分目标。
- **已登记设备列表**：额度栏图标 → popover，列出设备（名称 + 可选中 UDID + 状态徽章），支持名称/UDID 模糊搜索、刷新、固定高度。
- **结果区管理**：清除按钮；切换/删除当前账号时自动清空结果。
- **打包体验**：DMG 改为「拖入 应用程序」安装布局（app + /Applications 替身 + Finder 摆位）；新增两个双击式脚本 `配置公证凭据.command`、`打包.command`。

## 已知 Minor（不阻塞合并，后续可选）
- `AccountManagerView` 的 `.config` 导入分支未包安全域访问 guard（沙盒下 powerbox 授权在 URL 生命周期内有效，实际可用；与 `.p8` 分支写法可对齐）。
- `package.sh` 中 `DEV=$(hdiutil attach | grep | head)` 在极端情况下（attach 输出异常）可能残留挂载卷；下次运行会自愈（脚本开头会清同名卷）。
- DMG 内的 app 未单独 staple（仅 DMG 已 staple）；首次启动依赖联网校验公证——本 app 本就需要联网，无实际影响。要离线首启无提示，可在 `cp -R` 进 staging 前先 staple 该 .app。
- `配置公证凭据.command` 用 `--password` 传参，本地 `ps` 可短暂看到；单用户 Mac 低风险。

## 打包 / 分发
- 双击 `scripts/配置公证凭据.command`（一次性）→ 双击 `scripts/打包.command` → 产出 `dist/UDIDRegisterMac.dmg`（签名+公证+带图标+拖拽安装）。
- 面向同事的图文步骤见 [docs/同事使用说明.md](../同事使用说明.md)。
- 分发采用凭据本地下发模型：管理员「导出配置…」得 `.udidconfig`，安全渠道发给同事「导入配置文件…」一键配好。

## 状态
本轮评审通过，合并入 main。后续如需继续加功能，从 main 新开分支即可。
