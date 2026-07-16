import Foundation

public enum SubprocessError: Error, LocalizedError {
    case launch(String)
    case nonZero(status: Int32, stderr: String)
    public var errorDescription: String? {
        switch self {
        case .launch(let m): return "无法启动子进程：\(m)"
        case .nonZero(let s, let e): return "命令失败（退出码 \(s)）：\(e)"
        }
    }
}

public struct Subprocess {
    public struct Result {
        public let status: Int32
        public let stdout: String
        public let stderr: String
    }

    public static func run(_ launchPath: String, _ args: [String], input: Data? = nil) throws -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        p.standardOutput = out; p.standardError = err
        p.standardInput = inPipe   // 始终给一个可关闭的 stdin，避免子进程继承父进程 stdin
        do { try p.run() } catch { throw SubprocessError.launch(error.localizedDescription) }

        // 并发读 stdout/stderr，避免任一管道缓冲写满导致死锁
        var oData = Data(), eData = Data()
        let group = DispatchGroup()
        let q = DispatchQueue(label: "resignkit.subprocess.io", attributes: .concurrent)
        q.async(group: group) { oData = out.fileHandleForReading.readDataToEndOfFile() }
        q.async(group: group) { eData = err.fileHandleForReading.readDataToEndOfFile() }
        if let input { inPipe.fileHandleForWriting.write(input) }
        inPipe.fileHandleForWriting.closeFile()   // 关闭 → 子进程 stdin 见 EOF
        p.waitUntilExit()
        group.wait()
        return Result(status: p.terminationStatus,
                      stdout: String(decoding: oData, as: UTF8.self),
                      stderr: String(decoding: eData, as: UTF8.self))
    }

    @discardableResult
    public static func runChecked(_ launchPath: String, _ args: [String], input: Data? = nil) throws -> Result {
        let r = try run(launchPath, args, input: input)
        guard r.status == 0 else { throw SubprocessError.nonZero(status: r.status, stderr: r.stderr) }
        return r
    }
}
