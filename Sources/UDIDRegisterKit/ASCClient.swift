import Foundation

public enum ASCError: LocalizedError {
    case http(Int, String)
    public var errorDescription: String? {
        if case let .http(s, d) = self { return d.isEmpty ? "ASC API \(s)" : d }
        return nil
    }
}

public struct ASCClient {
    static let base = URL(string: "https://api.appstoreconnect.apple.com")!
    let http: HTTPClient
    let signJWT: (ASCCredentials) throws -> String

    public init(http: HTTPClient,
                signJWT: @escaping (ASCCredentials) throws -> String = ASCClient.defaultSign) {
        self.http = http; self.signJWT = signJWT
    }
    public static func defaultSign(_ c: ASCCredentials) throws -> String {
        try ASCJWT.sign(keyID: c.keyID, issuerID: c.issuerID, privateKeyPEM: c.privateKeyPEM)
    }
    func headers(_ c: ASCCredentials) throws -> [String: String] {
        ["Authorization": "Bearer \(try signJWT(c))", "Content-Type": "application/json"]
    }

    public func registerDevice(credentials c: ASCCredentials, name: String, udid: String) async throws -> RegistrationOutcome {
        let payload: [String: Any] = ["data": ["type": "devices",
            "attributes": ["name": name, "udid": udid, "platform": "IOS"]]]
        let resp = try await http.send(method: "POST",
            url: Self.base.appendingPathComponent("v1/devices"),
            headers: try headers(c), body: try JSONSerialization.data(withJSONObject: payload))
        let json = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any]

        if (200...299).contains(resp.status) {
            let attrs = (json?["data"] as? [String: Any])?["attributes"] as? [String: Any]
            return .created(status: DeviceStatus.from(attrs?["status"] as? String))
        }
        if resp.status == 409, let dev = try? await lookup(credentials: c, udid: udid) {
            return .alreadyExisted(name: dev.name, status: dev.status)
        }
        let detail = ((json?["errors"] as? [[String: Any]])?.first?["detail"] as? String) ?? "ASC API \(resp.status)"
        return .failed(message: detail)
    }

    public func listDevices(credentials c: ASCCredentials) async throws -> [DeviceRow] {
        var comp = URLComponents(url: Self.base.appendingPathComponent("v1/devices"), resolvingAgainstBaseURL: false)!
        comp.queryItems = [URLQueryItem(name: "limit", value: "200")]
        let resp = try await http.send(method: "GET", url: comp.url!, headers: try headers(c), body: nil)
        guard (200...299).contains(resp.status) else {
            let json = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any]
            let detail = ((json?["errors"] as? [[String: Any]])?.first?["detail"] as? String) ?? ""
            throw ASCError.http(resp.status, detail)
        }
        let json = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any]
        let arr = (json?["data"] as? [[String: Any]]) ?? []
        return arr.compactMap { item in
            guard let id = item["id"] as? String, let a = item["attributes"] as? [String: Any] else { return nil }
            return DeviceRow(id: id, name: a["name"] as? String ?? "", udid: a["udid"] as? String ?? "",
                             status: DeviceStatus.from(a["status"] as? String),
                             model: a["model"] as? String, addedDate: a["addedDate"] as? String)
        }
    }

    private func lookup(credentials c: ASCCredentials, udid: String) async throws -> DeviceRow? {
        let target = udid.uppercased()
        return try await listDevices(credentials: c).first { $0.udid.uppercased() == target }
    }
}
