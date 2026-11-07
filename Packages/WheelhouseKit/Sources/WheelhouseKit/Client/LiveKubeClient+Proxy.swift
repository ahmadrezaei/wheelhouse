import Foundation

// Live `proxyRequest` (M9): any HTTP method through the API server's service proxy. Used for the optional Argo CD API
// (read-only `managed-resources`); `proxyGET` stays as the Prometheus path.

extension LiveKubeClient {
    /// Headers the caller may never set: transport framing, hop-by-hop headers, and every credential header of the cluster
    /// (`Authorization`, `Proxy-Authorization`, `Impersonate-*`).
    private static let reservedProxyHeaders: Set<String> = ["host", "content-length", "connection", "transfer-encoding", "upgrade", "te", "trailer",
                                                            "authorization", "proxy-authorization", "keep-alive", "proxy-connection"]

    static func isReservedProxyHeader(_ name: String) -> Bool {
        let lower = name.lowercased()
        return reservedProxyHeaders.contains(lower) || lower.hasPrefix("impersonate-")
    }

    /// Builds the service-proxy path, e.g. `/api/v1/namespaces/argocd/services/https:argocd-server:443/proxy/api/v1/applications`.
    /// `service` may carry a scheme prefix (`https:argocd-server`); `port` is the port number or name.
    nonisolated static func proxyPath(namespace: String, service: String, port: String, path: String) throws -> String {
        try ProxyTarget.validate(namespace: namespace, service: service, port: port)
        var trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        try ProxyTarget.validate(path: trimmed)
        // Callers may pass raw or already-escaped paths: escape what is unsafe, keep existing %XX (a bad path must never trap URLComponents).
        trimmed = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.union(CharacterSet(charactersIn: "%"))) ?? trimmed
        return "/api/v1/namespaces/\(namespace)/services/\(service):\(port)/proxy/\(trimmed)"
    }

    /// Sends one request through the service proxy and returns the upstream status, headers and body. Non-2xx upstream statuses
    /// are returned, not thrown (the caller decides what a 401 or 404 from the target service means); transport failures throw.
    ///
    /// - A method other than GET or HEAD is a mutation and follows the cluster's read-only policy.
    /// - Caller headers can never carry a cluster credential: `Authorization`, `Proxy-Authorization` and `Impersonate-*` are dropped.
    ///   Other headers, such as `Cookie`, are forwarded by the proxy.
    /// - M3: this builds its own send path instead of `perform`, so the 401 token refresh that M3 adds to `perform` does not cover it.
    ///   When M3 lands, route the send below through the same refresh-and-retry step.
    public func proxyRequest(method: String, namespace: String, service: String, port: String, path: String, query: [String: String],
                             headers: [String: String], body: Data?) async throws -> ProxyResponse {
        let verb = method.uppercased()
        if verb != "GET" && verb != "HEAD",
           case .refuse = MutationPolicy.decide(.mutation(dryRun: false), cluster: config, origin: nil) {
            throw KubeError.readOnly
        }
        var request = try makeRequest(path: try Self.proxyPath(namespace: namespace, service: service, port: port, path: path),
                                      query: query.sorted { $0.key < $1.key }.map { ($0.key, $0.value) },
                                      method: verb, body: body, timeout: 30)
        for (name, value) in headers {
            if Self.isReservedProxyHeader(name) { continue }
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

/// Validation of everything that becomes part of a service-proxy URL, so a stored or typed value can never retarget the request.
public enum ProxyTarget {
    public static func isDNSLabel(_ s: String) -> Bool {
        guard (1...63).contains(s.count), let f = s.first, let l = s.last, f != "-", l != "-" else { return false }
        return s.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" }
    }

    /// A port number (1-65535) or an IANA service name (at most 15 characters, lowercase letters, digits and hyphens, one letter).
    public static func isPort(_ s: String) -> Bool {
        if !s.isEmpty, s.allSatisfy(\.isASCII), s.allSatisfy(\.isNumber) { return Int(s).map { (1...65535).contains($0) } ?? false }
        return s.count <= 15 && isDNSLabel(s) && s.contains { $0 >= "a" && $0 <= "z" } && !s.contains("--")
    }

    /// `service` may carry a scheme prefix: `https:argocd-server`.
    public static func validate(namespace: String, service: String, port: String) throws {
        let parts = service.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let ok = isDNSLabel(namespace) && isPort(port)
            && ((parts.count == 1 && isDNSLabel(parts[0])) || (parts.count == 2 && ["http", "https"].contains(parts[0]) && isDNSLabel(parts[1])))
        if !ok { throw KubeError.invalid(message: "Not a valid service proxy target (namespace, service and port must be DNS names or a port).", causes: []) }
    }

    /// Rejects `.` and `..` segments, raw or percent-encoded (also encoded twice), and encoded slashes.
    public static func validate(path: String) throws {
        for segment in path.split(separator: "/", omittingEmptySubsequences: false) {
            var current = String(segment)
            for _ in 0..<3 {
                if current == "." || current == ".." || current.contains("/") || current.contains("\\") {
                    throw KubeError.invalid(message: "A proxy path may not contain dot segments or encoded slashes.", causes: [])
                }
                guard let decoded = current.removingPercentEncoding, decoded != current else { break }
                current = decoded
            }
        }
    }

    /// For forms: a human message, or nil when valid.
    public static func problem(namespace: String, service: String, port: String, scheme: String) -> String? {
        if !isDNSLabel(namespace) { return "Namespace must be a lowercase DNS name." }
        if !isDNSLabel(service) { return "Service must be a lowercase DNS name." }
        if !isPort(port) { return "Port must be a number from 1 to 65535 or a port name." }
        if !scheme.isEmpty && !["http", "https"].contains(scheme) { return "Scheme must be http or https." }
        return nil
    }
}
