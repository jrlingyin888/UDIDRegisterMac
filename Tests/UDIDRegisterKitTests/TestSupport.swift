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

/// 按 (method, path) 返回预设响应
final class MockHTTP: HTTPClient, @unchecked Sendable {
    let handler: (String, String) -> HTTPResponse
    init(_ handler: @escaping (String, String) -> HTTPResponse) { self.handler = handler }
    func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> HTTPResponse {
        handler(method, url.path)
    }
    static func json(_ status: Int, _ obj: [String: Any]) -> HTTPResponse {
        HTTPResponse(status: status, body: try! JSONSerialization.data(withJSONObject: obj))
    }
}
