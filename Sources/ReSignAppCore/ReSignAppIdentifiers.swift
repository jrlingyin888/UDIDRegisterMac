import Foundation

/// ReSignApp 全局标识符。与注册 app 分开（各自独立的钥匙串 service）。
/// 打包脚本(计划4)会从本文件抽 bundleID 写入 Info.plist。
public enum ReSignAppIdentifiers {
    public static let bundleID = "com.pangu.ReSignMac"
}
