import Foundation

public struct AppleAccount: Identifiable, Codable, Hashable {
    public let id: UUID
    public var displayName: String
    public var keyID: String
    public var issuerID: String
    public var teamID: String?
    public init(id: UUID = UUID(), displayName: String, keyID: String, issuerID: String, teamID: String? = nil) {
        self.id = id; self.displayName = displayName; self.keyID = keyID
        self.issuerID = issuerID; self.teamID = teamID
    }
}

public struct ASCCredentials {
    public let keyID: String
    public let issuerID: String
    public let privateKeyPEM: String
    public init(keyID: String, issuerID: String, privateKeyPEM: String) {
        self.keyID = keyID; self.issuerID = issuerID; self.privateKeyPEM = privateKeyPEM
    }
}

public struct DeviceInput: Identifiable, Hashable {
    public let id: UUID
    public var udidRaw: String
    public var name: String
    public init(id: UUID = UUID(), udidRaw: String, name: String) {
        self.id = id; self.udidRaw = udidRaw; self.name = name
    }
}

public enum DeviceStatus: String, Codable, Hashable {
    case enabled = "ENABLED"
    case processing = "PROCESSING"
    case disabled = "DISABLED"
    case unknown = "UNKNOWN"
    public static func from(_ raw: String?) -> DeviceStatus {
        guard let raw else { return .unknown }
        return DeviceStatus(rawValue: raw) ?? .unknown
    }
}

public struct DeviceRow: Identifiable, Hashable {
    public let id: String
    public var name: String
    public var udid: String
    public var status: DeviceStatus
    public var model: String?
    public var addedDate: String?
    public init(id: String, name: String, udid: String, status: DeviceStatus, model: String? = nil, addedDate: String? = nil) {
        self.id = id; self.name = name; self.udid = udid; self.status = status; self.model = model; self.addedDate = addedDate
    }
}

public enum RegistrationOutcome: Hashable {
    case created(status: DeviceStatus)
    case alreadyExisted(name: String, status: DeviceStatus)
    case failed(message: String)
}
