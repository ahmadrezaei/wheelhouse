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

    public var problem: String? { ProxyTarget.problem(namespace: namespace, service: service, port: port, scheme: scheme) }

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
    case clusterForbidsProxy
    case http(Int, String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "Argo CD did not accept the token."
        case .clusterForbidsProxy: "The cluster forbids services/proxy for your user, so Wheelhouse cannot reach Argo CD through the API server."
        case .notFound: "Argo CD answered 404. Check the service location in Tides settings."
        case .http(let code, let m): "Argo CD answered \(code)\(m.isEmpty ? "" : ": \(m)")."
        case .badResponse: "Argo CD sent a response Wheelhouse could not read."
        }
    }
}

/// Read-only use of the Argo CD API through the Kubernetes service proxy. The user's token is sent as
/// `Cookie: argocd.token=<token>` because the API server's proxy strips `Authorization`. The token is never sent as a
/// bearer credential: to the API server it would be a (wrong) cluster credential.
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
        let response = try await send(["Cookie": "argocd.token=\(token)"])
        switch response.statusCode {
        case 200..<300: return response.body
        case 403 where Self.isClusterForbidden(response.body): throw ArgoAPIError.clusterForbidsProxy
        case 401, 403: throw ArgoAPIError.unauthorized
        case 404: throw ArgoAPIError.notFound
        default: throw ArgoAPIError.http(response.statusCode, String(data: response.body.prefix(200), encoding: .utf8) ?? "")
        }
    }

    /// A 403 written by the Kubernetes API server (a Status object about `services/proxy`), as opposed to one from Argo CD.
    static func isClusterForbidden(_ body: Data) -> Bool {
        guard let json = try? JSONValue.parse(body), json["kind"]?.stringValue == "Status" else { return false }
        let text = (json["message"]?.stringValue ?? "") + (json.value(at: "details.kind")?.stringValue ?? "")
        return text.contains("services/proxy") || text.contains("proxy")
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
