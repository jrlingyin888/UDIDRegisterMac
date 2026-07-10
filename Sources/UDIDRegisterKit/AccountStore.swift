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
        accounts.append(a); try persist(); return a
    }
    public func update(_ a: AppleAccount) throws {
        guard let i = accounts.firstIndex(where: { $0.id == a.id }) else { return }
        accounts[i] = a; try persist()
    }
    public func remove(id: UUID) throws {
        accounts.removeAll { $0.id == id }; try persist()
    }
}
