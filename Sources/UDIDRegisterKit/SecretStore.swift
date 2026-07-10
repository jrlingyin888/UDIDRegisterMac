import Foundation
import Security

public protocol SecretStore {
    func save(_ pem: String, for id: UUID) throws
    func load(for id: UUID) throws -> String?
    func delete(for id: UUID) throws
}

public final class InMemorySecretStore: SecretStore {
    private var store: [UUID: String] = [:]
    public init() {}
    public func save(_ pem: String, for id: UUID) throws { store[id] = pem }
    public func load(for id: UUID) throws -> String? { store[id] }
    public func delete(for id: UUID) throws { store[id] = nil }
}

public enum KeychainError: Error { case os(OSStatus) }

public final class KeychainSecretStore: SecretStore {
    let service: String
    public init(service: String = "com.yourco.UDIDRegisterMac") { self.service = service }

    public func save(_ pem: String, for id: UUID) throws {
        try delete(for: id)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecValueData as String: Data(pem.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked]
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.os(status) }
    }
    public func load(for id: UUID) throws -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError.os(status) }
        return String(decoding: data, as: UTF8.self)
    }
    public func delete(for id: UUID) throws {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString]
        let status = SecItemDelete(q as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.os(status) }
    }
}
