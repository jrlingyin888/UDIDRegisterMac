import Foundation

public enum CertificateType: String { case distribution = "DISTRIBUTION"; case development = "DEVELOPMENT" }
public enum ProfileType: String { case iosAppAdHoc = "IOS_APP_ADHOC" }

public struct BundleIdInfo: Hashable, Sendable {
    public let id: String
    public let identifier: String
    public let name: String
    public init(id: String, identifier: String, name: String) {
        self.id = id; self.identifier = identifier; self.name = name
    }
    public init?(json d: [String: Any]) {
        guard let id = d["id"] as? String, let a = d["attributes"] as? [String: Any],
              let identifier = a["identifier"] as? String else { return nil }
        self.init(id: id, identifier: identifier, name: (a["name"] as? String) ?? identifier)
    }
}

public struct CertificateInfo: Hashable, Sendable {
    public let id: String
    public let name: String
    public let contentDER: Data
    public let expirationDate: String?
    public let serialNumber: String?
    public init(id: String, name: String, contentDER: Data, expirationDate: String?, serialNumber: String?) {
        self.id = id; self.name = name; self.contentDER = contentDER
        self.expirationDate = expirationDate; self.serialNumber = serialNumber
    }
    public init?(json d: [String: Any]) {
        guard let id = d["id"] as? String, let a = d["attributes"] as? [String: Any] else { return nil }
        let content = (a["certificateContent"] as? String)
            .flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) } ?? Data()
        self.init(id: id, name: (a["name"] as? String) ?? "", contentDER: content,
                  expirationDate: a["expirationDate"] as? String, serialNumber: a["serialNumber"] as? String)
    }
}

public struct ProfileInfo: Hashable, Sendable {
    public let id: String
    public let name: String
    public let uuid: String?
    public let contentData: Data
    public init(id: String, name: String, uuid: String?, contentData: Data) {
        self.id = id; self.name = name; self.uuid = uuid; self.contentData = contentData
    }
    public init?(json d: [String: Any]) {
        guard let id = d["id"] as? String, let a = d["attributes"] as? [String: Any] else { return nil }
        let content = (a["profileContent"] as? String)
            .flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) } ?? Data()
        self.init(id: id, name: (a["name"] as? String) ?? "", uuid: a["uuid"] as? String, contentData: content)
    }
}
