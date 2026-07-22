import Foundation

public struct InjectableApp { public let appDir: URL; public let mainExecutable: URL }

public enum InjectError: Error, Equatable, LocalizedError {
    case notApp, encrypted, badArch(String), notMachO(String), insertFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notApp: return "IPA 结构异常：找不到 app 或其主程序"
        case .encrypted: return "该 IPA 仍加密（cryptid≠0），请先脱壳后再注入"
        case let .badArch(a): return "架构不支持（需 arm64）：\(a)"
        case let .notMachO(n): return "主程序不是 Mach-O：\(n)"
        case let .insertFailed(m): return "注入失败：\(m)"
        }
    }
}

public struct DylibInjector {
    /// 定位主程序（Info.plist 的 CFBundleExecutable），校验存在、arm64、未加密。
    public static func preflight(appDir: URL) throws -> InjectableApp {
        let info = appDir.appendingPathComponent("Info.plist")
        guard let d = NSDictionary(contentsOf: info),
              let exe = d["CFBundleExecutable"] as? String else { throw InjectError.notApp }
        let main = appDir.appendingPathComponent(exe)
        guard FileManager.default.isExecutableFile(atPath: main.path) else { throw InjectError.notApp }
        let archs = (try? MachOInspect.archs(main)) ?? []
        guard !archs.isEmpty else { throw InjectError.notMachO(exe) }
        guard archs.contains("arm64") else { throw InjectError.badArch(archs.joined(separator: ",")) }
        if (try? MachOInspect.isEncrypted(main)) == true { throw InjectError.encrypted }
        return InjectableApp(appDir: appDir, mainExecutable: main)
    }

    /// 注入一个插件 dylib：拷进 Frameworks/、（若依赖 substrate 且给了替换）改依赖指向 ElleKit、insert_dylib 插 LC_LOAD_DYLIB。
    public static func inject(plugin: URL, into app: InjectableApp,
                             insertDylibTool: URL, substrateReplacement: URL?) throws {
        let pArchs = (try? MachOInspect.archs(plugin)) ?? []
        guard pArchs.contains("arm64") else { throw InjectError.badArch("plugin: \(pArchs.joined(separator: ","))") }

        let fw = app.appDir.appendingPathComponent("Frameworks")
        try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
        let dest = fw.appendingPathComponent(plugin.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: plugin, to: dest)

        // 若插件依赖 CydiaSubstrate/libsubstrate 且提供了 ElleKit → 改依赖指向自带 ElleKit
        if let ellekit = substrateReplacement {
            let ekDest = fw.appendingPathComponent("ElleKit.dylib")
            if !FileManager.default.fileExists(atPath: ekDest.path) { try FileManager.default.copyItem(at: ellekit, to: ekDest) }
            let deps = (try? MachOInspect.dylibDependencies(dest)) ?? []
            for dep in deps where dep.contains("CydiaSubstrate") || dep.contains("libsubstrate") {
                _ = try? Subprocess.runChecked("/usr/bin/install_name_tool",
                    ["-change", dep, "@executable_path/Frameworks/ElleKit.dylib", dest.path])
            }
        }

        // 给主程序插 LC_LOAD_DYLIB → @executable_path/Frameworks/<plugin>
        let loadPath = "@executable_path/Frameworks/\(plugin.lastPathComponent)"
        let r = try Subprocess.run(insertDylibTool.path,
            ["--inplace", "--all-yes", loadPath, app.mainExecutable.path])
        guard r.status == 0 else { throw InjectError.insertFailed(r.stderr) }
    }
}
