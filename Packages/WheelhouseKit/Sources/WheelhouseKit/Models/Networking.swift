import Foundation

public struct Service: KubeObject {
    public static var resourceKind: ResourceKind { .service }
    public struct Port: Codable, Hashable, Sendable {
        public var name: String?
        public var `protocol`: String?
        public var port: Int
        public var targetPort: JSONValue?
        public var nodePort: Int?
    }
    public struct Spec: Codable, Hashable, Sendable {
        public var type: String?
        public var clusterIP: String?
        public var clusterIPs: [String]?
        public var externalName: String?
        public var externalIPs: [String]?
        @Lenient public var selector: [String: String]
        @Lenient public var ports: [Port]
        public var sessionAffinity: String?
    }
    public struct LBIngress: Codable, Hashable, Sendable { public var ip: String?; public var hostname: String? }
    public struct Status: Codable, Hashable, Sendable {
        public var loadBalancer: LoadBalancer?
        public struct LoadBalancer: Codable, Hashable, Sendable { @Lenient public var ingress: [LBIngress] }
    }
    public var metadata: ObjectMeta
    public var spec: Spec
    public var status: Status?
    public var externalAddress: String? {
        status?.loadBalancer?.ingress.compactMap { $0.ip ?? $0.hostname }.first ?? spec.externalIPs?.first
    }
}

public struct Ingress: KubeObject {
    public static var resourceKind: ResourceKind { .ingress }
    public struct Backend: Codable, Hashable, Sendable {
        public struct ServiceBackend: Codable, Hashable, Sendable {
            public var name: String
            public var port: PortRef?
            public struct PortRef: Codable, Hashable, Sendable { public var name: String?; public var number: Int? }
        }
        public var service: ServiceBackend?
    }
    public struct Path: Codable, Hashable, Sendable {
        public var path: String?
        public var pathType: String?
        public var backend: Backend
    }
    public struct Rule: Codable, Hashable, Sendable {
        public var host: String?
        public var http: HTTP?
        public struct HTTP: Codable, Hashable, Sendable { @Lenient public var paths: [Path] }
    }
    public struct TLS: Codable, Hashable, Sendable {
        @Lenient public var hosts: [String]
        public var secretName: String?
    }
    public struct Spec: Codable, Hashable, Sendable {
        public var ingressClassName: String?
        public var defaultBackend: Backend?
        @Lenient public var rules: [Rule]
        @Lenient public var tls: [TLS]
    }
    public struct Status: Codable, Hashable, Sendable {
        public var loadBalancer: Service.Status.LoadBalancer?
    }
    public var metadata: ObjectMeta
    public var spec: Spec
    public var status: Status?
}

public struct NetworkPolicy: KubeObject {
    public static var resourceKind: ResourceKind { .networkPolicy }
    public struct Spec: Codable, Hashable, Sendable {
        public var podSelector: LabelSelector?
        public var policyTypes: [String]?
        public var ingress: [JSONValue]?
        public var egress: [JSONValue]?
    }
    public var metadata: ObjectMeta
    public var spec: Spec
}

public struct Endpoints: KubeObject {
    public static var resourceKind: ResourceKind { .endpoints }
    public struct Address: Codable, Hashable, Sendable {
        public var ip: String
        public var nodeName: String?
        public var targetRef: ObjectReference?
    }
    public struct Port: Codable, Hashable, Sendable { public var name: String?; public var port: Int; public var `protocol`: String? }
    public struct Subset: Codable, Hashable, Sendable {
        @Lenient public var addresses: [Address]
        @Lenient public var notReadyAddresses: [Address]
        @Lenient public var ports: [Port]
    }
    public var metadata: ObjectMeta
    @Lenient public var subsets: [Subset]
    public var readyCount: Int { subsets.reduce(0) { $0 + $1.addresses.count } }
    public var notReadyCount: Int { subsets.reduce(0) { $0 + $1.notReadyAddresses.count } }
}

public struct EndpointSlice: KubeObject {
    public static var resourceKind: ResourceKind { .endpointSlice }
    public struct EndpointConditions: Codable, Hashable, Sendable {
        public var ready: Bool?
        public var serving: Bool?
        public var terminating: Bool?
    }
    public struct Endpoint: Codable, Hashable, Sendable {
        @Lenient public var addresses: [String]
        public var conditions: EndpointConditions?
        public var nodeName: String?
        public var zone: String?
        public var targetRef: ObjectReference?
    }
    public struct Port: Codable, Hashable, Sendable { public var name: String?; public var port: Int?; public var `protocol`: String? }
    public var metadata: ObjectMeta
    public var addressType: String?
    @Lenient public var endpoints: [Endpoint]
    @Lenient public var ports: [Port]
}
