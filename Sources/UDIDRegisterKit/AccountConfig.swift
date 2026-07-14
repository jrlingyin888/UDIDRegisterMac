import Foundation

/// 一键配置文件（.udidconfig）的内容。含私钥，仅经安全渠道分发。
public struct AccountConfig: Codable, Equatable {
    public var schemaVersion: Int
    public var displayName: String
    public var keyID: String
    public var issuerID: String
    public var teamID: String?
    public var p8PEM: String
    public init(schemaVersion: Int, displayName: String, keyID: String,
                issuerID: String, teamID: String?, p8PEM: String) {
        self.schemaVersion = schemaVersion; self.displayName = displayName
        self.keyID = keyID; self.issuerID = issuerID; self.teamID = teamID; self.p8PEM = p8PEM
    }
}

public enum AccountConfigError: Error, LocalizedError {
    case unsupportedVersion(Int)
    case malformed
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return "配置文件版本不支持（version \(v)），请让管理员用新版重新导出"
        case .malformed:
            return "配置文件格式不正确，无法读取，请让管理员重新导出"
        }
    }
}

public enum AccountConfigCodec {
    public static let currentVersion = 1

    public static func encode(_ config: AccountConfig) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(config)
    }

    public static func decode(_ data: Data) throws -> AccountConfig {
        let config: AccountConfig
        do { config = try JSONDecoder().decode(AccountConfig.self, from: data) }
        catch { throw AccountConfigError.malformed }
        guard config.schemaVersion == currentVersion else {
            throw AccountConfigError.unsupportedVersion(config.schemaVersion)
        }
        guard !config.displayName.isEmpty, !config.keyID.isEmpty, !config.issuerID.isEmpty,
              config.p8PEM.contains("PRIVATE KEY") else {
            throw AccountConfigError.malformed
        }
        return config
    }
}
