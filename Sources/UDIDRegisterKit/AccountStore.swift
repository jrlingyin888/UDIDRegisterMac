import Foundation

public final class AccountStore {
    private let fileURL: URL
    public private(set) var accounts: [AppleAccount] = []

    public init(fileURL: URL) { self.fileURL = fileURL; load() }

    public static func defaultFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UDIDRegisterMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("accounts.json")
    }
    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([AppleAccount].self, from: data) else { return }
        accounts = list
    }
    private func persist() throws {
        try JSONEncoder().encode(accounts).write(to: fileURL, options: .atomic)
    }
    @discardableResult public func add(_ a: AppleAccount) throws -> AppleAccount {
        let previous = accounts
        accounts.append(a)
        do { try persist() } catch { accounts = previous; throw error }
        return a
    }
    public func update(_ a: AppleAccount) throws {
        guard let i = accounts.firstIndex(where: { $0.id == a.id }) else { return }
        let previous = accounts
        accounts[i] = a
        do { try persist() } catch { accounts = previous; throw error }
    }
    public func remove(id: UUID) throws {
        let previous = accounts
        accounts.removeAll { $0.id == id }
        do { try persist() } catch { accounts = previous; throw error }
    }
}
