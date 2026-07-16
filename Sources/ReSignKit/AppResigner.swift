import Foundation

public struct AppResigner {
    public static func resign(appDir: URL, identity: TemporaryKeychainIdentity,
                              profileData: Data, entitlements: [String: Any]) throws {
        let bundle = AppBundle(appDir: appDir)
        // ① 写描述文件
        try profileData.write(to: bundle.embeddedProfileURL())
        // ② entitlements 落临时 plist
        let entURL = appDir.deletingLastPathComponent().appendingPathComponent("entitlements-\(UUID().uuidString).plist")
        let entData = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
        try entData.write(to: entURL)
        defer { try? FileManager.default.removeItem(at: entURL) }

        // ③ 由内向外签名
        let targets = bundle.codeToSignInsideOut()
        for t in targets {
            let isMainApp = (t == appDir)
            let args = CodesignInvocation.signArgs(identity: identity.signingIdentity,
                        target: t.path, entitlements: isMainApp ? entURL.path : nil)
                        + ["--keychain", identity.keychainPath]
            let r = try Subprocess.run("/usr/bin/codesign", args)
            guard r.status == 0 else { throw ReSignError.codesignFailed("\(t.lastPathComponent): \(r.stderr)") }
        }
        // ④ 验签
        let v = try Subprocess.run("/usr/bin/codesign",
            CodesignInvocation.verifyArgs(target: appDir.path) + ["--keychain", identity.keychainPath])
        guard v.status == 0 else { throw ReSignError.codesignFailed("verify: \(v.stderr)") }
    }
}
