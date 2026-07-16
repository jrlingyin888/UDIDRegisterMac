import Foundation

extension ASCClient {
    // MARK: - Bundle IDs
    public func listBundleIds(credentials c: ASCCredentials, identifier: String) async throws -> [BundleIdInfo] {
        var comp = URLComponents(url: Self.base.appendingPathComponent("v1/bundleIds"), resolvingAgainstBaseURL: false)!
        comp.queryItems = [URLQueryItem(name: "filter[identifier]", value: identifier),
                           URLQueryItem(name: "limit", value: "200")]
        let resp = try await http.send(method: "GET", url: comp.url!, headers: try headers(c), body: nil)
        try Self.ensureOK(resp)
        let arr = (Self.jsonObject(resp)?["data"] as? [[String: Any]]) ?? []
        return arr.compactMap(BundleIdInfo.init(json:))
    }

    public func createBundleId(credentials c: ASCCredentials, identifier: String, name: String) async throws -> BundleIdInfo {
        let payload: [String: Any] = ["data": ["type": "bundleIds",
            "attributes": ["identifier": identifier, "name": name, "platform": "IOS"]]]
        let resp = try await http.send(method: "POST",
            url: Self.base.appendingPathComponent("v1/bundleIds"),
            headers: try headers(c), body: try JSONSerialization.data(withJSONObject: payload))
        try Self.ensureOK(resp)
        guard let d = Self.jsonObject(resp)?["data"] as? [String: Any], let info = BundleIdInfo(json: d) else {
            throw ASCError.http(resp.status, "创建 Bundle ID 返回异常")
        }
        return info
    }

    public func findOrCreateBundleId(credentials c: ASCCredentials, identifier: String, name: String) async throws -> BundleIdInfo {
        if let existing = try await listBundleIds(credentials: c, identifier: identifier).first { return existing }
        return try await createBundleId(credentials: c, identifier: identifier, name: name)
    }

    // MARK: - Helpers
    static func ensureOK(_ resp: HTTPResponse) throws {
        guard (200...299).contains(resp.status) else {
            let detail = ((jsonObject(resp)?["errors"] as? [[String: Any]])?.first?["detail"] as? String) ?? ""
            throw ASCError.http(resp.status, detail)
        }
    }
    static func jsonObject(_ resp: HTTPResponse) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any]
    }
    static func pemCSR(_ der: Data) -> String {
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE REQUEST-----\n\(b64)\n-----END CERTIFICATE REQUEST-----\n"
    }
}
