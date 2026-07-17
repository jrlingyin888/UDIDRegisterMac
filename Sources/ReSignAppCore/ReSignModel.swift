import Foundation
import Observation
import UDIDRegisterKit
import ReSignKit

public enum IdentityStatus: Equatable { case notCreated; case ready }

public enum ReSignAppError: LocalizedError {
    case msg(String)
    public var errorDescription: String? { if case let .msg(m) = self { return m }; return nil }
}

@MainActor
@Observable
public final class ReSignModel {
    public var accounts: [AppleAccount] = []
    public var selectedID: UUID?
    public var log: [String] = []
    public var busy = false
    public var banner: String?
    public var selectedIPA: URL?

    let store: AccountStore
    let secrets: SecretStore
    let identity: SigningIdentityManager
    let client: ASCClient

    public init(store: AccountStore, secrets: SecretStore,
                identity: SigningIdentityManager, client: ASCClient) {
        self.store = store; self.secrets = secrets; self.identity = identity; self.client = client
        reload()
    }

    public func reload() {
        accounts = store.accounts
        if selectedID == nil || !accounts.contains(where: { $0.id == selectedID }) {
            selectedID = accounts.first?.id
        }
    }
    public var selected: AppleAccount? { accounts.first { $0.id == selectedID } }

    public func identityStatus(for accountID: UUID) -> IdentityStatus {
        ((try? identity.identity(for: accountID)) ?? nil) == nil ? .notCreated : .ready
    }

    func credentials(for a: AppleAccount) throws -> ASCCredentials {
        guard let pem = try secrets.load(for: a.id) else { throw ReSignAppError.msg("找不到该账号的 .p8，请重新导入账号") }
        return ASCCredentials(keyID: a.keyID, issuerID: a.issuerID, privateKeyPEM: pem)
    }

    /// 复用注册助手导出的 AccountConfig：解析 → 联网校验 → 存账号 + .p8。
    public func importAccountConfig(from url: URL) async -> Bool {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { banner = "读取配置文件失败：\(UserFacingMessage.from(error))"; return false }
        let config: AccountConfig
        do { config = try AccountConfigCodec.decode(data) }
        catch { banner = UserFacingMessage.from(error); return false }
        let account = AppleAccount(displayName: config.displayName, keyID: config.keyID,
                                   issuerID: config.issuerID, teamID: config.teamID)
        let cred = ASCCredentials(keyID: config.keyID, issuerID: config.issuerID, privateKeyPEM: config.p8PEM)
        do { _ = try await client.listDevices(credentials: cred) }
        catch { banner = "凭据校验失败：\(UserFacingMessage.from(error))"; return false }
        do { try secrets.save(config.p8PEM, for: account.id); try store.add(account) }
        catch { try? secrets.delete(for: account.id); banner = "保存失败：\(UserFacingMessage.from(error))"; return false }
        reload(); selectedID = account.id; banner = nil
        return true
    }

    public func deleteAccount(id: UUID) {
        try? secrets.delete(for: id)
        try? identity.store.remove(for: id)
        try? store.remove(id: id)
        reload()
    }
}
