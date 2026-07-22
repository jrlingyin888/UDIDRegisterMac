import Foundation

/// 定位随 app 打包的注入工具（insert_dylib）与运行时（ElleKit.dylib）。
/// 打包后从 app bundle 的 Resources/inject/ 取；dev/测试（`swift run`/`swift test`，CWD=包根）
/// 从仓库 Resources/inject/ 取。两处都找不到则抛中文错误。
public enum BundledInjectTools {
    public static var insertDylib: URL { get throws { try tool("insert_dylib") } }
    public static var ellekit: URL { get throws { try tool("ElleKit.dylib") } }

    static func tool(_ name: String) throws -> URL {
        // ① 打包后的 app：Contents/Resources/inject/<name>
        if let res = Bundle.main.resourceURL {
            let u = res.appendingPathComponent("inject/\(name)")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        // ② dev/测试：<CWD>/Resources/inject/<name>
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/inject/\(name)")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        throw ReSignAppError.msg("找不到内置注入工具：\(name)（打包时未随 app 附带）")
    }
}
