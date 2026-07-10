# UDID 注册助手（UDIDRegisterMac）

一个纯本地的 macOS 原生 app：管理员在 app 内管理一个或多个苹果开发者账号凭据（`.p8` + Issuer ID + Key ID），把测试机 UDID 录入 app（单条或批量），app 直接调用 App Store Connect（ASC）API 完成设备注册，并展示每台设备的真实状态（已可用 / 处理中 / 已存在等）与账号的「已用 X / 100」额度。

全程**无本地服务器、无隧道、无云后台**；`.p8` 私钥**只存在本机 Keychain**，不落盘、不出本机。

这是 Cloudflare Worker 版 `udid-register`（内部 QA 自助注册工具）的原生化演进，用于独立分发/售卖。

## 环境要求

- macOS 14+
- Xcode 15+ / Swift 5.9+ 工具链

## 开发

```bash
swift test                    # 跑 UDIDRegisterKit 单元测试
swift run UDIDRegisterApp     # 本地运行 app（未签名，调试用）
```

## 打包（签名 + 公证 + DMG）

`scripts/package.sh` 会：release 构建 → 拼 `.app` bundle → `codesign`（含 sandbox entitlements）→ `hdiutil` 生成 DMG → `notarytool` 提交公证 → `stapler` 装订公证票据。

### 前置条件

1. 一张 **Developer ID Application** 证书，已导入本机 Keychain（Apple Developer Program 账号下载）。
2. 用 `xcrun notarytool store-credentials` 保存一份公证用的 keychain profile：

   ```bash
   xcrun notarytool store-credentials "your-profile-name" \
     --apple-id "you@example.com" \
     --team-id "TEAMID" \
     --password "app-specific-password"
   ```

3. 打包时通过环境变量传入证书名与 profile 名：

   ```bash
   DEV_ID_APP="Developer ID Application: NAME (TEAMID)" \
   NOTARY_PROFILE="your-profile-name" \
   bash scripts/package.sh
   ```

成功后产出已公证、已装订的 `dist/UDIDRegisterMac.dmg`，可直接分发。

### ⚠️ 替换 bundle id 前缀

仓库中的 bundle id 占位符是 `com.yourco.UDIDRegisterMac`。分发前**必须**把 `com.yourco` 替换成你自己的真实前缀（例如 `com.acme`），并且要在**两处保持完全一致**，否则打包出的 app 读不到 Keychain 里已保存的凭据（Keychain 条目按 service 名匹配，对不上就等于账号数据丢失）：

1. `scripts/package.sh` 里 Info.plist 的 `CFBundleIdentifier`。
2. `Sources/UDIDRegisterKit/SecretStore.swift` 中 `KeychainSecretStore(service:)` 的默认值。

两处改完后重新 `swift build` / 重新打包。

## 安全说明

- `.p8` 私钥只存在本机 **Keychain**（通过 `KeychainSecretStore`），从不写入磁盘文件、从不上传。
- app 运行在 App Sandbox 下（见 `Resources/UDIDRegisterMac.entitlements`），仅申请 `network.client`（调用 ASC API）和 `files.user-selected.read-only`（导入 `.p8` 文件）两项权限。
- 无授权/激活/远程后台，账号与凭据管理完全在本机完成。

## 已知限制

- Apple 账号年度设备额度 100 台，注册后**不可删除**，仅能「禁用」且仍占用额度直到年度重置窗口。
- 不支持 Windows / 跨平台，不上架 Mac App Store（可作为未来选项）。
