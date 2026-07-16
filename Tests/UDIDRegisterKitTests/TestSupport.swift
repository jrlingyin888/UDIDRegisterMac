import Foundation
@testable import UDIDRegisterKit

extension Data {
    /// 解码 base64url（无填充）
    init?(base64URLEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b) else { return nil }
        self = d
    }
}

/// 按 (method, path) 返回预设响应；同时记录每次请求以便断言请求体/查询串
final class MockHTTP: HTTPClient, @unchecked Sendable {
    let handler: (String, String) -> HTTPResponse
    private let lock = NSLock()
    private var _requests: [(method: String, url: URL, body: Data?)] = []
    var requests: [(method: String, url: URL, body: Data?)] {
        lock.lock(); defer { lock.unlock() }; return _requests
    }
    init(_ handler: @escaping (String, String) -> HTTPResponse) { self.handler = handler }
    func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> HTTPResponse {
        lock.lock(); _requests.append((method, url, body)); lock.unlock()
        return handler(method, url.path)
    }
    static func json(_ status: Int, _ obj: [String: Any]) -> HTTPResponse {
        HTTPResponse(status: status, body: try! JSONSerialization.data(withJSONObject: obj))
    }
}
