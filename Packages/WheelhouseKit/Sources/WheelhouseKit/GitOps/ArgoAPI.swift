import Foundation

/// Where Argo CD's API server is reachable from the Kubernetes API server's service proxy.
public struct ArgoServiceLocation: Hashable, Codable, Sendable {
    public var namespace: String
    public var service: String
    public var port: String
    /// `https` for the stock install (`https:argocd-server:443`); `http` when the server runs with `--insecure`; empty for none.
    public var scheme: String

    public init(namespace: String = "argocd", service: String = "argocd-server", port: String = "443", scheme: String = "https") {
        self.namespace = namespace
        self.service = service
        self.port = port
        self.scheme = scheme
    }

    /// The `service` path segment of the proxy URL (`https:argocd-server`).
    public var proxyService: String { scheme.isEmpty ? service : "\(scheme):\(service)" }
}

public struct ArgoManagedResource: Hashable, Sendable, Identifiable {
    public var group: String
    public var kind: String
    public var namespace: String?
    public var name: String
    public var liveState: String?
    public var targetState: String?
    public var normalizedLiveState: String?
    public var predictedLiveState: String?
    public var modified: Bool
    public var id: String { "\(group)/\(kind)/\(namespace ?? "")/\(name)" }
    public var display: String { [kind, namespace, name].compactMap { $0 }.joined(separator: "/") }

    /// Unified line diff between what is live (normalised) and what Git would produce (predicted), as YAML.
    public func diff() -> [DiffLine] {
        func yaml(_ s: String?) -> String {
            guard let s, !s.isEmpty, s != "null", let json = try? JSONValue.parse(Data(s.utf8)) else { return "" }
            return YAMLCodec.dump(json)
        }
        return LineDiff.diff(old: yaml(normalizedLiveState ?? liveState), new: yaml(predictedLiveState ?? targetState))
    }
}

public enum ArgoAPIError: Error, LocalizedError, Equatable {
    case unauthorized
    case notFound
    case http(Int, String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "Argo CD did not accept the token."
        case .notFound: "Argo CD answered 404. Check the service location in Tides settings."
        case .http(let code, let m): "Argo CD answered \(code)\(m.isEmpty ? "" : ": \(m)")."
        case .badResponse: "Argo CD sent a response Wheelhouse could not read."
        }
    }
}

/// Read-only use of the Argo CD API through the Kubernetes service proxy. The user's token is sent as
/// `Cookie: argocd.token=<token>` because the API server's proxy strips `Authorization`; a second attempt with
/// `Authorization: Bearer` is made only after a 401, for proxies that do forward it.
public struct ArgoAPI: Sendable {
    public var client: any KubeClientProtocol
    public var location: ArgoServiceLocation
    public var token: String

    public init(client: any KubeClientProtocol, location: ArgoServiceLocation, token: String) {
        self.client = client
        self.location = location
        self.token = token
    }

    /// Only GET is ever sent.
    func get(_ path: String, query: [String: String] = [:]) async throws -> Data {
        func send(_ headers: [String: String]) async throws -> ProxyResponse {
            try await client.proxyRequest(method: "GET", namespace: location.namespace, service: location.proxyService, port: location.port,
                                          path: path, query: query, headers: headers.merging(["Accept": "application/json"]) { $1 }, body: nil)
        }
        var response = try await send(["Cookie": "argocd.token=\(token)"])
        if response.statusCode == 401 || response.statusCode == 403 {
            response = try await send(["Authorization": "Bearer \(token)"])
        }
        switch response.statusCode {
        case 200..<300: return response.body
        case 401, 403: throw ArgoAPIError.unauthorized
        case 404: throw ArgoAPIError.notFound
        default: throw ArgoAPIError.http(response.statusCode, String(data: response.body.prefix(200), encoding: .utf8) ?? "")
        }
    }

    /// `GET /api/v1/applications/<name>/managed-resources`
    public func managedResources(application: String, appNamespace: String? = nil) async throws -> [ArgoManagedResource] {
        let escaped = application.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? application
        var query: [String: String] = [:]
        if let appNamespace, !appNamespace.isEmpty { query["appNamespace"] = appNamespace }
        let data = try await get("/api/v1/applications/\(escaped)/managed-resources", query: query)
        return try Self.decodeManagedResources(data)
    }

    /// `GET /api/v1/session/userinfo`: proves the token works without reading anything else.
    public func checkToken() async throws -> String? {
        let data = try await get("/api/v1/session/userinfo")
        guard let json = try? JSONValue.parse(data) else { throw ArgoAPIError.badResponse }
        return json["username"]?.stringValue
    }

    static func decodeManagedResources(_ data: Data) throws -> [ArgoManagedResource] {
        guard let json = try? JSONValue.parse(data) else { throw ArgoAPIError.badResponse }
        return (json["items"]?.arrayValue ?? []).compactMap { v in
            guard let kind = v["kind"]?.stringValue, let name = v["name"]?.stringValue else { return nil }
            let ns = v["namespace"]?.stringValue
            return ArgoManagedResource(group: v["group"]?.stringValue ?? "", kind: kind, namespace: (ns?.isEmpty ?? true) ? nil : ns, name: name,
                                       liveState: v["liveState"]?.stringValue, targetState: v["targetState"]?.stringValue,
                                       normalizedLiveState: v["normalizedLiveState"]?.stringValue, predictedLiveState: v["predictedLiveState"]?.stringValue,
                                       modified: v["modified"]?.boolValue ?? false)
        }
    }
}
