import Foundation
import UDIDRegisterKit

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
