import Foundation
import UDIDRegisterKit
import ReSignKit

extension ReSignModel {
    /// ReSignApp 专属账号文件（与注册 app 的 UDIDRegisterMac 目录分开）。
    public static func liveAccountsFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReSignMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("accounts.json")
    }

    /// 生产接线：ReSignApp 自己的账号库 + 钥匙串 service（`com.pangu.ReSignMac`）+ 签名身份库 + 真实 ASCClient。
    @MainActor public static func live() -> ReSignModel {
        ReSignModel(
            store: AccountStore(fileURL: liveAccountsFileURL()),
            secrets: KeychainSecretStore(service: ReSignAppIdentifiers.bundleID),
            identity: SigningIdentityManager(store: KeychainSigningIdentityStore()),
            client: ASCClient(http: URLSessionHTTPClient()))
    }
}
