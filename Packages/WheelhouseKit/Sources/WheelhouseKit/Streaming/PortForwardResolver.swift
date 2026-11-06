import Foundation

/// A concrete pod and container port a forward should connect to.
public struct ResolvedEndpoint: Hashable, Sendable {
    public var pod: String
    public var port: Int
}

/// Resolves a ``PortForwardTarget`` to a ready pod. Services go through EndpointSlices (falling back to Endpoints).
public struct PortForwardResolver: Sendable {
    public let client: any KubeClientProtocol
    public init(client: any KubeClientProtocol) { self.client = client }

    public func resolve(_ target: PortForwardTarget, preferring previous: String? = nil) async throws -> ResolvedEndpoint {
        switch target.kind {
        case .pod:
            return ResolvedEndpoint(pod: target.name, port: target.remotePort)
        case .service:
            return try await resolveService(target, preferring: previous)
        }
    }

    func resolveService(_ target: PortForwardTarget, preferring previous: String?) async throws -> ResolvedEndpoint {
        let service = try await client.get(Service.self, name: target.name, namespace: target.namespace)
        let svcPort = service.spec.ports.first { $0.port == target.remotePort }
        var fallbackPort = target.remotePort
        if case .int(let n)? = svcPort?.targetPort { fallbackPort = n }

        let slices = try? await client.list(EndpointSlice.self, namespace: target.namespace,
                                            options: ListOptions(labelSelector: "kubernetes.io/service-name=\(target.name)"))
        var candidates: [ResolvedEndpoint] = []
        for slice in slices?.items ?? [] {
            let port = slice.ports.first { ($0.name ?? "") == (svcPort?.name ?? "") }?.port ?? slice.ports.first?.port ?? fallbackPort
            for ep in slice.endpoints where ep.conditions?.ready != false && ep.conditions?.terminating != true {
                if let ref = ep.targetRef, ref.kind == "Pod", let name = ref.name {
                    candidates.append(ResolvedEndpoint(pod: name, port: port))
                }
            }
        }
        if candidates.isEmpty, let endpoints = try? await client.get(Endpoints.self, name: target.name, namespace: target.namespace) {
            for subset in endpoints.subsets {
                let port = subset.ports.first { ($0.name ?? "") == (svcPort?.name ?? "") }?.port ?? subset.ports.first?.port ?? fallbackPort
                for addr in subset.addresses {
                    if let ref = addr.targetRef, ref.kind == "Pod", let name = ref.name {
                        candidates.append(ResolvedEndpoint(pod: name, port: port))
                    }
                }
            }
        }
        guard !candidates.isEmpty else {
            throw PortForwardError.noReadyPod("Service \(target.name) has no ready pods to forward to.")
        }
        candidates.sort { $0.pod < $1.pod }
        if let previous, let same = candidates.first(where: { $0.pod == previous }) { return same }
        return candidates[0]
    }
}
