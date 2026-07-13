import Foundation

/// 把内部错误翻成面向非技术同事的中文提示。
public enum UserFacingMessage {
    public static func from(_ error: Error) -> String {
        switch error {
        case let ascError as ASCError:
            if case let .http(status, detail) = ascError {
                if status == 401 || status == 403 {
                    return "凭据无效或已过期，请检查 Key ID / Issuer ID / .p8 是否正确"
                }
                return detail.isEmpty ? "请求失败（ASC API \(status)）" : "请求失败：\(detail)"
            }
            return ascError.localizedDescription
        case let jwtError as ASCJWTError:
            switch jwtError {
            case .invalidPrivateKey:
                return "这个 .p8 文件无法识别，请确认是从 App Store Connect 下载的原始 .p8 文件"
            }
        case is URLError:
            return "网络连接失败，请检查网络后重试"
        case let keychainError as KeychainError:
            if case let .os(status) = keychainError {
                return "本机凭据存取失败（Keychain 错误码 \(status)）"
            }
            return "本机凭据存取失败"
        default:
            return error.localizedDescription
        }
    }
}
