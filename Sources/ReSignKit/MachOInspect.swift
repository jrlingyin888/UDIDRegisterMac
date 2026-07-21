import Foundation

/// 读 Mach-O 关键信息：是否 FairPlay 加密、CPU 架构、LC_LOAD_DYLIB 依赖。
public enum MachOInspect {
    /// 从 `otool -l` 文本判断是否仍加密：存在 LC_ENCRYPTION_INFO(_64) 且 cryptid != 0。
    public static func cryptidIsEncrypted(otoolLoadCommands s: String) -> Bool {
        guard s.contains("LC_ENCRYPTION_INFO") else { return false }
        for line in s.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("cryptid") {
                let v = t.dropFirst("cryptid".count).trimmingCharacters(in: .whitespaces)
                if v != "0" { return true }
            }
        }
        return false
    }
    /// 从 `otool -l` 文本抽取 LC_LOAD_DYLIB 的 name（去掉 " (offset N)" 尾巴）。
    public static func loadDylibs(otoolLoadCommands s: String) -> [String] {
        var out: [String] = []
        var lines = ArraySlice(s.split(separator: "\n", omittingEmptySubsequences: false))
        while let line = lines.first {
            lines = lines.dropFirst()
            if line.trimmingCharacters(in: .whitespaces) == "cmd LC_LOAD_DYLIB" {
                if let nameLine = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("name ") }) {
                    var n = nameLine.trimmingCharacters(in: .whitespaces).dropFirst("name ".count)
                    if let r = n.range(of: " (offset ") { n = n[..<r.lowerBound] }
                    out.append(String(n))
                }
            }
        }
        return out
    }

    public static func isEncrypted(_ macho: URL) throws -> Bool {
        let r = try Subprocess.runChecked("/usr/bin/otool", ["-l", macho.path])
        return cryptidIsEncrypted(otoolLoadCommands: r.stdout)
    }
    public static func archs(_ macho: URL) throws -> [String] {
        let r = try Subprocess.runChecked("/usr/bin/lipo", ["-archs", macho.path])
        return r.stdout.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init).filter { !$0.isEmpty }
    }
    public static func dylibDependencies(_ macho: URL) throws -> [String] {
        let r = try Subprocess.runChecked("/usr/bin/otool", ["-l", macho.path])
        return loadDylibs(otoolLoadCommands: r.stdout)
    }
}
