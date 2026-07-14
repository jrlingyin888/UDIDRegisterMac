import Foundation

public enum UDIDNormalizer {
    /// 规范化 UDID；非法返回 nil。
    /// 40 位十六进制 → 小写；8-16 带连字符 → 大写。
    public static func normalize(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.range(of: "^[0-9a-f]{8}-[0-9a-f]{16}$", options: .regularExpression) != nil {
            return s.uppercased()
        }
        if s.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil {
            return s
        }
        return nil
    }
}
