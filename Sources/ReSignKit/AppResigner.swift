import Foundation

public struct AppResigner {
    public static func resign(appDir: URL, identity: TemporaryKeychainIdentity,
                              profileData: Data, entitlements: [String: Any]) throws {
        let bundle = AppBundle(appDir: appDir)

        // entitlements 落临时 plist（所有可执行 bundle 共用同一份通配 entitlements）
        let entURL = FileManager.default.temporaryDirectory.appendingPathComponent("entitlements-\(UUID().uuidString).plist")
        let entData = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
        try entData.write(to: entURL)
        defer { try? FileManager.default.removeItem(at: entURL) }

        // 由内向外签名。可执行 bundle（主 app / *.appex / Watch/*.app）：塞各自 embedded.mobileprovision + 带
        // entitlements 签；库（*.framework / *.dylib）：不塞 profile、不带 entitlements。
        // 顺序由 codeToSignInsideOut 保证（库/appex/watch 在前，主 app 最后），故每个 appex 的描述文件+签名
        // 会被随后主 app 的签名封入。
        let targets = bundle.codeToSignInsideOut()
        for t in targets {
            let isExecBundle = (t == appDir) || t.pathExtension == "appex" || t.pathExtension == "app"
            if isExecBundle {
                try profileData.write(to: AppBundle(appDir: t).embeddedProfileURL())
            }
            let args = CodesignInvocation.signArgs(identity: identity.signingIdentity,
                        target: t.path, entitlements: isExecBundle ? entURL.path : nil)
                        + ["--keychain", identity.keychainPath]
            let r = try Subprocess.run("/usr/bin/codesign", args)
            guard r.status == 0 else { throw ReSignError.codesignFailed("\(t.lastPathComponent): \(r.stderr)") }
        }

        // 验签整棵嵌套签名树
        let v = try Subprocess.run("/usr/bin/codesign",
            CodesignInvocation.verifyArgs(target: appDir.path) + ["--keychain", identity.keychainPath])
        guard v.status == 0 else { throw ReSignError.codesignFailed("verify: \(v.stderr)") }
    }

    /// 推荐入口：entitlements 从描述文件抽取，保证不越权
    public static func resign(appDir: URL, identity: TemporaryKeychainIdentity,
                              mobileprovisionData: Data) throws {
        let profile = try ProvisioningProfile.load(fromMobileprovisionData: mobileprovisionData)
        try resign(appDir: appDir, identity: identity,
                   profileData: mobileprovisionData, entitlements: profile.entitlements)
    }
}
