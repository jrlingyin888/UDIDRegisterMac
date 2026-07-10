import Foundation
import Observation
import UDIDRegisterKit

struct RowResult: Identifiable {
    let id = UUID()
    let name: String
    let udid: String
    let outcome: RegistrationOutcome
}

enum AppError: LocalizedError {
    case msg(String)
    var errorDescription: String? { if case let .msg(m) = self { return m }; return nil }
}

@MainActor
@Observable
final class AppModel {
    var accounts: [AppleAccount] = []
    var selectedID: UUID?
    var quotaText: String = ""
    var results: [RowResult] = []
    var registering = false
    var banner: String?

    let store: AccountStore
    let secrets: SecretStore
    let client: ASCClient

    init(store: AccountStore = AccountStore(fileURL: AccountStore.defaultFileURL()),
         secrets: SecretStore = KeychainSecretStore(),
         client: ASCClient = ASCClient(http: URLSessionHTTPClient())) {
        self.store = store; self.secrets = secrets; self.client = client
        reload()
    }
    func reload() {
        accounts = store.accounts
        if selectedID == nil || !accounts.contains(where: { $0.id == selectedID }) {
            selectedID = accounts.first?.id
        }
    }
    var selected: AppleAccount? { accounts.first { $0.id == selectedID } }

    func credentials(for a: AppleAccount) throws -> ASCCredentials {
        guard let pem = try secrets.load(for: a.id) else { throw AppError.msg("找不到该账号的 .p8，请重新添加") }
        return ASCCredentials(keyID: a.keyID, issuerID: a.issuerID, privateKeyPEM: pem)
    }
}

extension AppModel {
    /// 校验凭据（签 JWT + 拉一页设备），成功则存账号 + 存 .p8 到 Keychain。
    func addAccount(displayName: String, keyID: String, issuerID: String,
                    teamID: String?, p8PEM: String) async -> Bool {
        let account = AppleAccount(displayName: displayName, keyID: keyID, issuerID: issuerID, teamID: teamID)
        let cred = ASCCredentials(keyID: keyID, issuerID: issuerID, privateKeyPEM: p8PEM)
        // 1) 校验凭据
        do {
            _ = try await client.listDevices(credentials: cred)
        } catch {
            banner = "凭据校验失败：\(error.localizedDescription)"
            return false
        }
        // 2) 持久化：Keychain 写成功但账号写失败时，回滚 Keychain，避免孤儿密钥
        do {
            try secrets.save(p8PEM, for: account.id)
            try store.add(account)
        } catch {
            try? secrets.delete(for: account.id)
            banner = "保存失败：\(error.localizedDescription)"
            return false
        }
        reload()
        selectedID = account.id
        banner = nil
        return true
    }
    func deleteAccount(id: UUID) {
        try? secrets.delete(for: id)
        try? store.remove(id: id)
        reload()
    }
    /// 返回设备数（额度已用）或错误
    func testConnection(for a: AppleAccount) async -> Result<Int, Error> {
        do {
            let cred = try credentials(for: a)
            let rows = try await client.listDevices(credentials: cred)
            return .success(rows.count)
        } catch { return .failure(error) }
    }
}
