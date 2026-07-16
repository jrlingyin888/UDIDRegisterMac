import Foundation

public enum ReSignError: Error, LocalizedError {
    case invalidProfile
    case appNotFound
    case noExecutable
    case codesignFailed(String)
    case identityImport(String)
    case unsupportedNestedBundle([String])
    public var errorDescription: String? {
        switch self {
        case .invalidProfile: return "描述文件无法解析（不是有效的 .mobileprovision）"
        case .appNotFound: return "IPA 内找不到 Payload/*.app"
        case .noExecutable: return "app bundle 缺少可执行文件"
        case .codesignFailed(let m): return "codesign 失败：\(m)"
        case .identityImport(let m): return "导入签名身份失败：\(m)"
        case .unsupportedNestedBundle(let names):
            return "暂不支持含扩展/Watch 的 app(需为每个子 bundle 单独生成描述文件):\(names.joined(separator: ", "))"
        }
    }
}

public struct ProvisioningProfile {
    public let entitlements: [String: Any]
    public let name: String
    public let uuid: String
    public let teamIdentifier: String?
    public let deviceUDIDs: [String]

    public init?(plist: [String: Any]) {
        guard let ent = plist["Entitlements"] as? [String: Any] else { return nil }
        self.entitlements = ent
        self.name = (plist["Name"] as? String) ?? ""
        self.uuid = (plist["UUID"] as? String) ?? ""
        self.teamIdentifier = (plist["TeamIdentifier"] as? [String])?.first
        self.deviceUDIDs = (plist["ProvisionedDevices"] as? [String]) ?? []
    }

    /// `security cms -D` 解出 .mobileprovision 内嵌的 plist
    public static func decodePlist(fromMobileprovision url: URL) throws -> [String: Any] {
        let r = try Subprocess.runChecked("/usr/bin/security", ["cms", "-D", "-i", url.path])
        guard let data = r.stdout.data(using: .utf8),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else { throw ReSignError.invalidProfile }
        return dict
    }

    public static func load(fromMobileprovision url: URL) throws -> ProvisioningProfile {
        guard let p = ProvisioningProfile(plist: try decodePlist(fromMobileprovision: url)) else {
            throw ReSignError.invalidProfile
        }
        return p
    }

    /// 从 .mobileprovision 原始字节解析（内部写临时文件走 security cms -D）
    public static func load(fromMobileprovisionData data: Data) throws -> ProvisioningProfile {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp-\(UUID().uuidString).mobileprovision")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try load(fromMobileprovision: tmp)
    }
}
