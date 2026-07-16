import Foundation

public enum CodesignInvocation {
    public static func signArgs(identity: String, target: String, entitlements: String?) -> [String] {
        var a = ["--force", "--sign", identity]
        if let entitlements { a += ["--entitlements", entitlements] }
        a += ["--timestamp=none", target]   // ad hoc 分发不需要时间戳服务
        return a
    }
    public static func verifyArgs(target: String) -> [String] {
        ["--verify", "--deep", "--strict", "--verbose=2", target]
    }
}
