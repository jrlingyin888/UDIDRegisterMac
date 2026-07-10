import Foundation

public struct HTTPResponse {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

public protocol HTTPClient {
    func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> HTTPResponse
}

public struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> HTTPResponse {
        var req = URLRequest(url: url)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        let (data, resp) = try await session.data(for: req)
        return HTTPResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}
