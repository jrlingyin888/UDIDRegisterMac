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
