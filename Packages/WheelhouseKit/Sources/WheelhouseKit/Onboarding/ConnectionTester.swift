import Foundation

/// What the connection test found. Everything optional so partial results (e.g. version OK, RBAC denied) render.
public struct ConnectionTestResult: Sendable, Equatable {
    public struct Capability: Sendable, Equatable, Identifiable {
        public var id: String { title }
        public var title: String
        public var allowed: Bool?
        public var detail: String?
    }
    public var version: String?
    public var latency: Duration?
    public var nodeCount: Int?
    public var capabilities: [Capability] = []
    public var error: KubeError?
    /// The version call succeeded (credentials accepted by the API server).
    public var reachable: Bool { version != nil }
    public var succeeded: Bool { error == nil && version != nil }

    public var latencyMilliseconds: Int? {
        latency.map { Int(($0.components.seconds * 1000) + ($0.components.attoseconds / 1_000_000_000_000_000)) }
    }
}

/// Runs `/version`, an RBAC probe (SelfSubjectAccessReview) and a node count against a client.
public enum ConnectionTester {
    struct Check: Sendable {
        var title: String
        /// Allowed if ANY verb is allowed. Exec and port-forward are WebSocket GETs on servers before Kubernetes 1.35 (`get`)
        /// and `create` from 1.35 on, so both are probed.
        var verbs: [String]
        var group: String
        var resource: String
        var subresource: String?
        var namespaced: Bool
    }

    static let checks: [Check] = [
        Check(title: "List workloads", verbs: ["list"], group: "apps", resource: "deployments", subresource: nil, namespaced: true),
        Check(title: "Watch pods", verbs: ["watch"], group: "", resource: "pods", subresource: nil, namespaced: true),
        Check(title: "Read Secrets", verbs: ["get"], group: "", resource: "secrets", subresource: nil, namespaced: true),
        Check(title: "Exec into pods", verbs: ["get", "create"], group: "", resource: "pods", subresource: "exec", namespaced: true),
        Check(title: "Port-forward", verbs: ["get", "create"], group: "", resource: "pods", subresource: "portforward", namespaced: true),
        Check(title: "Delete pods", verbs: ["delete"], group: "", resource: "pods", subresource: nil, namespaced: true),
    ]

    /// `namespace` scopes the namespaced probes (use the cluster's default namespace); nil asks about all namespaces.
    public static func run(client: any KubeClientProtocol, namespace: String? = nil) async -> ConnectionTestResult {
        var result = ConnectionTestResult()
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let v = try await client.version()
            result.latency = clock.now - start
            result.version = v.gitVersion
        } catch let e as KubeError {
            result.error = e
            return result
        } catch {
            result.error = .unreachable(cause: error.localizedDescription)
            return result
        }
        // Capabilities and node count in parallel; failures here are not fatal.
        await withTaskGroup(of: (Int, Bool?, String?).self) { group in
            for (i, check) in checks.enumerated() {
                group.addTask {
                    var allowed = false
                    var firstError: String?
                    for verb in check.verbs {
                        do {
                            var attrs: [String: JSONValue] = [
                                "verb": .string(verb), "group": .string(check.group), "resource": .string(check.resource),
                                "subresource": .string(check.subresource ?? ""),
                            ]
                            if check.namespaced, let namespace, !namespace.isEmpty { attrs["namespace"] = .string(namespace) }
                            let body: JSONValue = [
                                "apiVersion": "authorization.k8s.io/v1", "kind": "SelfSubjectAccessReview",
                                "spec": ["resourceAttributes": .object(attrs)],
                            ]
                            let r = try await client.create(.selfSubjectAccessReview, namespace: nil, body: body)
                            if r.value(at: "status.allowed")?.boolValue == true { allowed = true; break }
                        } catch let e as KubeError {
                            firstError = firstError ?? e.summary
                        } catch { firstError = firstError ?? error.localizedDescription }
                    }
                    if allowed { return (i, true, nil) }
                    return (i, firstError == nil ? false : nil, firstError)
                }
            }
            var caps = [ConnectionTestResult.Capability?](repeating: nil, count: checks.count)
            for await (i, allowed, detail) in group {
                caps[i] = .init(title: checks[i].title, allowed: allowed, detail: detail)
            }
            result.capabilities = caps.compactMap { $0 }
        }
        if let nodes = try? await client.list(Node.self, options: ListOptions(limit: 500)) {
            result.nodeCount = nodes.items.count
        }
        return result
    }
}
