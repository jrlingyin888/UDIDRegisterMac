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

    /// App ID 的 name 字段苹果只允许「字母数字和空格」（bundle id 里的 . _ - 会被拒）。
    /// 把非法字符换成空格、合并多余空格并裁剪；全非法时回退为 "App"（不能为空）。
    static func sanitizedAppIdName(_ raw: String) -> String {
        let mapped = raw.map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) || ch == " " ? ch : " "
        }
        let collapsed = String(mapped).split(separator: " ").joined(separator: " ")
        return collapsed.isEmpty ? "App" : collapsed
    }

    public func createBundleId(credentials c: ASCCredentials, identifier: String, name: String) async throws -> BundleIdInfo {
        let payload: [String: Any] = ["data": ["type": "bundleIds",
            "attributes": ["identifier": identifier, "name": Self.sanitizedAppIdName(name), "platform": "IOS"]]]
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

    // MARK: - Certificates
    public func listCertificates(credentials c: ASCCredentials, type: CertificateType) async throws -> [CertificateInfo] {
        var comp = URLComponents(url: Self.base.appendingPathComponent("v1/certificates"), resolvingAgainstBaseURL: false)!
        comp.queryItems = [URLQueryItem(name: "filter[certificateType]", value: type.rawValue),
                           URLQueryItem(name: "limit", value: "200")]
        let resp = try await http.send(method: "GET", url: comp.url!, headers: try headers(c), body: nil)
        try Self.ensureOK(resp)
        let arr = (Self.jsonObject(resp)?["data"] as? [[String: Any]]) ?? []
        return arr.compactMap(CertificateInfo.init(json:))
    }

    public func createCertificate(credentials c: ASCCredentials, csrDER: Data, type: CertificateType) async throws -> CertificateInfo {
        let payload: [String: Any] = ["data": ["type": "certificates",
            "attributes": ["certificateType": type.rawValue, "csrContent": Self.pemCSR(csrDER)]]]
        let resp = try await http.send(method: "POST",
            url: Self.base.appendingPathComponent("v1/certificates"),
            headers: try headers(c), body: try JSONSerialization.data(withJSONObject: payload))
        try Self.ensureOK(resp)
        guard let d = Self.jsonObject(resp)?["data"] as? [String: Any], let info = CertificateInfo(json: d) else {
            throw ASCError.http(resp.status, "创建证书返回异常")
        }
        guard !info.contentDER.isEmpty else { throw ASCError.http(resp.status, "创建证书返回缺少内容") }
        return info
    }

    // MARK: - Profiles
    public func listProfiles(credentials c: ASCCredentials, name: String) async throws -> [ProfileInfo] {
        var comp = URLComponents(url: Self.base.appendingPathComponent("v1/profiles"), resolvingAgainstBaseURL: false)!
        comp.queryItems = [URLQueryItem(name: "filter[name]", value: name),
                           URLQueryItem(name: "limit", value: "200")]
        let resp = try await http.send(method: "GET", url: comp.url!, headers: try headers(c), body: nil)
        try Self.ensureOK(resp)
        let arr = (Self.jsonObject(resp)?["data"] as? [[String: Any]]) ?? []
        return arr.compactMap(ProfileInfo.init(json:))
    }

    public func deleteProfile(credentials c: ASCCredentials, id: String) async throws {
        let resp = try await http.send(method: "DELETE",
            url: Self.base.appendingPathComponent("v1/profiles/\(id)"),
            headers: try headers(c), body: nil)
        try Self.ensureOK(resp)
    }

    public func createAdHocProfile(credentials c: ASCCredentials, name: String,
                                   bundleIdResourceId: String, certificateId: String,
                                   deviceIds: [String]) async throws -> ProfileInfo {
        let payload: [String: Any] = ["data": [
            "type": "profiles",
            "attributes": ["name": name, "profileType": ProfileType.iosAppAdHoc.rawValue],
            "relationships": [
                "bundleId": ["data": ["type": "bundleIds", "id": bundleIdResourceId]],
                "certificates": ["data": [["type": "certificates", "id": certificateId]]],
                "devices": ["data": deviceIds.map { ["type": "devices", "id": $0] }]
            ]
        ]]
        let resp = try await http.send(method: "POST",
            url: Self.base.appendingPathComponent("v1/profiles"),
            headers: try headers(c), body: try JSONSerialization.data(withJSONObject: payload))
        try Self.ensureOK(resp)
        guard let d = Self.jsonObject(resp)?["data"] as? [String: Any], let info = ProfileInfo(json: d) else {
            throw ASCError.http(resp.status, "创建描述文件返回异常")
        }
        guard !info.contentData.isEmpty else { throw ASCError.http(resp.status, "创建描述文件返回缺少内容") }
        return info
    }

    /// 删除同名旧 profile 后重建，带上传入的全部设备（加设备后自动纳入新 UDID）。
    public func refreshAdHocProfile(credentials c: ASCCredentials, name: String,
                                    bundleIdResourceId: String, certificateId: String,
                                    deviceIds: [String]) async throws -> ProfileInfo {
        for old in try await listProfiles(credentials: c, name: name) {
            try await deleteProfile(credentials: c, id: old.id)
        }
        return try await createAdHocProfile(credentials: c, name: name,
            bundleIdResourceId: bundleIdResourceId, certificateId: certificateId, deviceIds: deviceIds)
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
