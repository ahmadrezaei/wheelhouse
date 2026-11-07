import Foundation

// Live `proxyRequest` (M9): any HTTP method through the API server's service proxy. Used for the optional Argo CD API
// (read-only `managed-resources`); `proxyGET` stays as the Prometheus path.

extension LiveKubeClient {
    /// Headers the caller may never set: transport framing.
    private static let reservedProxyHeaders: Set<String> = ["host", "content-length", "connection", "transfer-encoding", "upgrade", "te", "trailer"]

    /// Builds the service-proxy path, e.g. `/api/v1/namespaces/argocd/services/https:argocd-server:443/proxy/api/v1/applications`.
    /// `service` may carry a scheme prefix (`https:argocd-server`); `port` is the port number or name.
    nonisolated static func proxyPath(namespace: String, service: String, port: String, path: String) -> String {
        var trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        // Callers may pass raw or already-escaped paths: escape what is unsafe, keep existing %XX (a bad path must never trap URLComponents).
        trimmed = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.union(CharacterSet(charactersIn: "%"))) ?? trimmed
        return "/api/v1/namespaces/\(ResourceKind.escape(namespace))/services/\(ResourceKind.escape(service)):\(ResourceKind.escape(port))/proxy/\(trimmed)"
    }

    /// Sends one request through the service proxy and returns the upstream status, headers and body. Non-2xx upstream statuses
    /// are returned, not thrown (the caller decides what a 401 or 404 from the target service means); transport failures throw.
    ///
    /// - A method other than GET or HEAD is a mutation and follows the cluster's read-only policy.
    /// - The cluster's own `Authorization` header is never replaced by a caller header while this cluster authenticates with a
    ///   bearer token (the API server would reject the proxy call). Other headers, such as `Cookie`, are forwarded by the proxy.
    public func proxyRequest(method: String, namespace: String, service: String, port: String, path: String, query: [String: String],
                             headers: [String: String], body: Data?) async throws -> ProxyResponse {
        let verb = method.uppercased()
        if verb != "GET" && verb != "HEAD",
           case .refuse = MutationPolicy.decide(.mutation(dryRun: false), cluster: config, origin: nil) {
            throw KubeError.readOnly
        }
        var request = try makeRequest(path: Self.proxyPath(namespace: namespace, service: service, port: port, path: path),
                                      query: query.sorted { $0.key < $1.key }.map { ($0.key, $0.value) },
                                      method: verb, body: body, timeout: 30)
        for (name, value) in headers {
            let lower = name.lowercased()
            if Self.reservedProxyHeaders.contains(lower) { continue }
            if lower == "authorization", request.value(forHTTPHeaderField: "Authorization") != nil { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw KubeError.decoding("Not an HTTP response") }
            var out: [String: String] = [:]
            for (k, v) in http.allHeaderFields { if let k = k as? String, let v = v as? String { out[k] = v } }
            return ProxyResponse(statusCode: http.statusCode, headers: out, body: data)
        } catch { throw mapTransportError(error) }
    }
}
