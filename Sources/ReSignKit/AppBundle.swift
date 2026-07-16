import Foundation

public struct AppBundle {
    public let appDir: URL
    public init(appDir: URL) { self.appDir = appDir }

    public func infoPlistURL() -> URL { appDir.appendingPathComponent("Info.plist") }
    public func embeddedProfileURL() -> URL { appDir.appendingPathComponent("embedded.mobileprovision") }

    public func bundleIdentifier() throws -> String {
        let data = try Data(contentsOf: infoPlistURL())
        let obj = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = obj as? [String: Any], let id = dict["CFBundleIdentifier"] as? String else {
            throw ReSignError.invalidProfile
        }
        return id
    }

    /// 由内向外收集需签名的代码：嵌套 framework/dylib/appex/watch app 在前，主 app 最后。
    public func codeToSignInsideOut() -> [URL] {
        let fm = FileManager.default
        var nested: [URL] = []
        // 注意：FileManager.contentsOfDirectory(at:) 在 macOS 上会把返回的 URL 解析到
        // 真实路径（例如 /var -> /private/var），并为目录项附带尾部 "/"，与调用方持有
        // 的未解析、无尾部斜杠的 URL 不再 `==`。因此这里始终基于传入的 `dir`（未解析）
        // 以 isDirectory:false 重新拼接子项路径，而不是直接使用枚举返回的 URL，以保证
        // 返回值与调用方期望的 URL 完全一致。
        func collect(in dir: URL, exts: Set<String>) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
            for u in items where exts.contains(u.pathExtension) {
                nested.append(dir.appendingPathComponent(u.lastPathComponent, isDirectory: false))
            }
        }
        collect(in: appDir.appendingPathComponent("Frameworks"), exts: ["framework", "dylib"])
        collect(in: appDir.appendingPathComponent("PlugIns"), exts: ["appex"])
        // Watch app（若有）：Watch/*.app 及其内层 PlugIns
        let watch = appDir.appendingPathComponent("Watch")
        if let watchApps = try? fm.contentsOfDirectory(at: watch, includingPropertiesForKeys: nil) {
            for w0 in watchApps where w0.pathExtension == "app" {
                let w = watch.appendingPathComponent(w0.lastPathComponent, isDirectory: false)
                collect(in: w.appendingPathComponent("Frameworks"), exts: ["framework", "dylib"])
                collect(in: w.appendingPathComponent("PlugIns"), exts: ["appex"])
                nested.append(w)
            }
        }
        return nested + [appDir]   // 主 app 最后
    }

    /// 需要各自独立描述文件的嵌套可执行 bundle：PlugIns/*.appex 与 Watch/*.app
    public func nestedExecutableBundles() -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for (sub, ext) in [("PlugIns", "appex"), ("Watch", "app"), ("AppClips", "app")] {
            let dir = appDir.appendingPathComponent(sub)
            if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                out += items.filter { $0.pathExtension == ext }
            }
        }
        return out
    }
}
