import Foundation

public struct IPAResigner {
    public static func findPayloadApp(in unpackedDir: URL) -> URL? {
        let payload = unpackedDir.appendingPathComponent("Payload")
        let items = (try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)) ?? []
        return items.first { $0.pathExtension == "app" }
    }

    /// 重签前 peek：解出 Payload/*.app/Info.plist 的 CFBundleIdentifier
    public static func readBundleIdentifier(ipaURL: URL) throws -> String {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("peek-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try Subprocess.runChecked("/usr/bin/ditto", ["-x", "-k", ipaURL.path, work.path])
        guard let app = findPayloadApp(in: work) else { throw ReSignError.appNotFound }
        return try AppBundle(appDir: app).bundleIdentifier()
    }

    public static func resign(ipaURL: URL, outputURL: URL, identity: TemporaryKeychainIdentity,
                              profileData: Data, entitlements: [String: Any]) throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ipa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // 解包
        try Subprocess.runChecked("/usr/bin/ditto", ["-x", "-k", ipaURL.path, work.path])
        guard let app = findPayloadApp(in: work) else { throw ReSignError.appNotFound }

        // 重签
        try AppResigner.resign(appDir: app, identity: identity, profileData: profileData, entitlements: entitlements)

        // 重打包（覆盖已存在的输出）
        try? FileManager.default.removeItem(at: outputURL)
        try Subprocess.runChecked("/usr/bin/ditto",
            ["-c", "-k", "--sequesterRsrc", "--keepParent",
             work.appendingPathComponent("Payload").path, outputURL.path])
    }

    /// 推荐入口：entitlements 从描述文件抽取
    public static func resign(ipaURL: URL, outputURL: URL, identity: TemporaryKeychainIdentity,
                              mobileprovisionData: Data) throws {
        let profile = try ProvisioningProfile.load(fromMobileprovisionData: mobileprovisionData)
        try resign(ipaURL: ipaURL, outputURL: outputURL, identity: identity,
                   profileData: mobileprovisionData, entitlements: profile.entitlements)
    }
}
