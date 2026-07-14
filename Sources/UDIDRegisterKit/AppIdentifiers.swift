import Foundation

/// App 全局标识符的唯一真值来源。
/// 注意：打包脚本 scripts/package.sh 会从本文件抽取 bundleID 写入 Info.plist，
/// 必须与 Keychain service 保持一致，否则打包版读不出已存的凭据。
public enum AppIdentifiers {
    public static let bundleID = "com.pangu.UDIDRegisterMac"
}
