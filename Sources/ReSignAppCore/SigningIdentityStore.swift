import Foundation
import Security

public protocol SigningIdentityStore {
    func identity(for accountID: UUID) throws -> SigningIdentity?
    func save(_ identity: SigningIdentity, for accountID: UUID) throws
    func remove(for accountID: UUID) throws
}

/// 存进钥匙串（generic password），value 是 {key,cert,ascId} 的 base64 JSON。
public final class KeychainSigningIdentityStore: SigningIdentityStore {
    let service: String
    public init(service: String = ReSignAppIdentifiers.bundleID + ".signing") { self.service = service }

    private struct Blob: Codable { let key: String; let cert: String; let ascId: String }

    public func save(_ identity: SigningIdentity, for accountID: UUID) throws {
        try remove(for: accountID)
        let blob = Blob(key: identity.privateKeyDER.base64EncodedString(),
                        cert: identity.certificateDER.base64EncodedString(),
                        ascId: identity.ascCertificateId)
        let data = try JSONEncoder().encode(blob)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw SigningIdentityError.keychain(status) }
    }

    public func identity(for accountID: UUID) throws -> SigningIdentity? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw SigningIdentityError.keychain(status) }
        let blob = try JSONDecoder().decode(Blob.self, from: data)
        guard let key = Data(base64Encoded: blob.key), let cert = Data(base64Encoded: blob.cert) else {
            throw SigningIdentityError.badKeyData
        }
        return SigningIdentity(privateKeyDER: key, certificateDER: cert, ascCertificateId: blob.ascId)
    }

    public func remove(for accountID: UUID) throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString]
        let status = SecItemDelete(q as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SigningIdentityError.keychain(status) }
    }
}

public final class InMemorySigningIdentityStore: SigningIdentityStore {
    private var map: [UUID: SigningIdentity] = [:]
    public init() {}
    public func identity(for accountID: UUID) throws -> SigningIdentity? { map[accountID] }
    public func save(_ identity: SigningIdentity, for accountID: UUID) throws { map[accountID] = identity }
    public func remove(for accountID: UUID) throws { map[accountID] = nil }
}
