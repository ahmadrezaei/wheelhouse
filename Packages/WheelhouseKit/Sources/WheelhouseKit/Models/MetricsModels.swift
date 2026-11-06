import Foundation

/// metrics.k8s.io NodeMetrics
public struct NodeMetrics: KubeObject {
    public static var resourceKind: ResourceKind { .nodeMetrics }
    public var metadata: ObjectMeta
    public var timestamp: Date?
    public var window: String?
    public var usage: [String: Quantity]
    public var cpuCores: Double { usage["cpu"]?.cores ?? 0 }
    public var memoryBytes: Double { usage["memory"]?.bytes ?? 0 }
}

/// metrics.k8s.io PodMetrics
public struct PodMetrics: KubeObject {
    public static var resourceKind: ResourceKind { .podMetrics }
    public struct ContainerMetrics: Codable, Hashable, Sendable {
        public var name: String
        public var usage: [String: Quantity]
    }
    public var metadata: ObjectMeta
    public var timestamp: Date?
    public var window: String?
    @Lenient public var containers: [ContainerMetrics]
    public var cpuCores: Double { containers.reduce(0) { $0 + ($1.usage["cpu"]?.cores ?? 0) } }
    public var memoryBytes: Double { containers.reduce(0) { $0 + ($1.usage["memory"]?.bytes ?? 0) } }
}
