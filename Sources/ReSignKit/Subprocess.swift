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
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        let inPipe = Pipe()
        if input != nil { p.standardInput = inPipe }
        do { try p.run() } catch { throw SubprocessError.launch(error.localizedDescription) }
        if let input { inPipe.fileHandleForWriting.write(input); inPipe.fileHandleForWriting.closeFile() }
        let oData = out.fileHandleForReading.readDataToEndOfFile()
        let eData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
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
