import Foundation

public enum DeviceInputParser {
    public static func parse(_ text: String) -> [DeviceInput] {
        text.split(whereSeparator: \.isNewline).compactMap { raw -> DeviceInput? in
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            let parts = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            let udid = parts[0].trimmingCharacters(in: .whitespaces)
            guard !udid.isEmpty else { return nil }
            var name = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            if name.isEmpty { name = defaultName(for: udid) }
            return DeviceInput(udidRaw: udid, name: name)
        }
    }
    static func defaultName(for udid: String) -> String {
        let tail = udid.replacingOccurrences(of: "-", with: "").suffix(6).uppercased()
        return "Device-\(tail)"
    }
}
