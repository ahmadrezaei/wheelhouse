import Foundation

public struct Taint: Codable, Hashable, Sendable {
    public var key: String
    public var value: String?
    public var effect: String
}

public struct NodeSystemInfo: Codable, Hashable, Sendable {
    public var machineID: String?
    public var kernelVersion: String?
    public var osImage: String?
    public var containerRuntimeVersion: String?
    public var kubeletVersion: String?
    public var kubeProxyVersion: String?
    public var operatingSystem: String?
    public var architecture: String?
}

public struct NodeAddress: Codable, Hashable, Sendable { public var type: String; public var address: String }

public struct Node: KubeObject {
    public static var resourceKind: ResourceKind { .node }
    public struct Spec: Codable, Hashable, Sendable {
        public var unschedulable: Bool?
        public var providerID: String?
        public var podCIDR: String?
        @Lenient public var taints: [Taint]
    }
    public struct Status: Codable, Hashable, Sendable {
        public var capacity: [String: Quantity]?
        public var allocatable: [String: Quantity]?
        @Lenient public var conditions: [Condition]
        @Lenient public var addresses: [NodeAddress]
        public var nodeInfo: NodeSystemInfo?
    }
    public var metadata: ObjectMeta
    public var spec: Spec
    public var status: Status?

    public var isUnschedulable: Bool { spec.unschedulable ?? false }
    public var readyCondition: Condition? { status?.conditions.first { $0.type == "Ready" } }
    public var isReady: Bool { readyCondition?.isTrue ?? false }
    /// Pressure conditions that are currently true (MemoryPressure, DiskPressure, PIDPressure, NetworkUnavailable).
    public var activePressure: [Condition] {
        (status?.conditions ?? []).filter { ["MemoryPressure", "DiskPressure", "PIDPressure", "NetworkUnavailable"].contains($0.type) && $0.isTrue }
    }
    public var instanceType: String? { metadata.labels["node.kubernetes.io/instance-type"] ?? metadata.labels["beta.kubernetes.io/instance-type"] }
    public var zone: String? { metadata.labels["topology.kubernetes.io/zone"] ?? metadata.labels["failure-domain.beta.kubernetes.io/zone"] }
    public var roles: [String] {
        metadata.labels.keys.compactMap { $0.hasPrefix("node-role.kubernetes.io/") ? String($0.dropFirst("node-role.kubernetes.io/".count)) : nil }.sorted()
    }
    public var nodePool: String? {
        metadata.labels["cloud.google.com/gke-nodepool"] ?? metadata.labels["eks.amazonaws.com/nodegroup"]
            ?? metadata.labels["agentpool"] ?? metadata.labels["node.kubernetes.io/instance-type"]
    }
}

public struct Namespace: KubeObject {
    public static var resourceKind: ResourceKind { .namespace }
    public struct Status: Codable, Hashable, Sendable { public var phase: String? }
    public var metadata: ObjectMeta
    public var status: Status?
}

/// core/v1 Event
public struct KubeEvent: KubeObject {
    public static var resourceKind: ResourceKind { .event }
    public var metadata: ObjectMeta
    public var involvedObject: ObjectReference
    public var reason: String?
    public var message: String?
    public var type: String?
    public var count: Int?
    public var firstTimestamp: Date?
    public var lastTimestamp: Date?
    public var eventTime: Date?
    public var source: Source?
    public var reportingComponent: String?
    public struct Source: Codable, Hashable, Sendable { public var component: String?; public var host: String? }

    public var isWarning: Bool { type == "Warning" }
    /// Best available "last seen" timestamp.
    public var lastSeen: Date? { lastTimestamp ?? eventTime ?? firstTimestamp ?? metadata.creationTimestamp }
}

/// events.k8s.io/v1 Event
public struct EventsV1Event: KubeObject {
    public static var resourceKind: ResourceKind { .eventsV1 }
    public struct Series: Codable, Hashable, Sendable { public var count: Int?; public var lastObservedTime: Date? }
    public var metadata: ObjectMeta
    public var regarding: ObjectReference?
    public var related: ObjectReference?
    public var reason: String?
    public var note: String?
    public var type: String?
    public var action: String?
    public var eventTime: Date?
    public var series: Series?
    public var deprecatedCount: Int?
    public var deprecatedLastTimestamp: Date?
    public var reportingController: String?

    public var isWarning: Bool { type == "Warning" }
    public var lastSeen: Date? { series?.lastObservedTime ?? deprecatedLastTimestamp ?? eventTime ?? metadata.creationTimestamp }
}

public struct CustomResourceDefinition: KubeObject {
    public static var resourceKind: ResourceKind { .customResourceDefinition }
    public struct Names: Codable, Hashable, Sendable {
        public var plural: String
        public var singular: String?
        public var kind: String
        public var shortNames: [String]?
        public var categories: [String]?
    }
    public struct PrinterColumn: Codable, Hashable, Sendable {
        public var name: String
        public var type: String?
        public var jsonPath: String
        public var description: String?
        public var priority: Int?
    }
    public struct Version: Codable, Hashable, Sendable {
        public var name: String
        public var served: Bool
        public var storage: Bool
        @Lenient public var additionalPrinterColumns: [PrinterColumn]
    }
    public struct Spec: Codable, Hashable, Sendable {
        public var group: String
        public var scope: String
        public var names: Names
        @Lenient public var versions: [Version]
    }
    public struct Status: Codable, Hashable, Sendable { @Lenient public var conditions: [Condition] }
    public var metadata: ObjectMeta
    public var spec: Spec
    public var status: Status?

    /// Converts to a ``ResourceKind`` for the storage (or first served) version.
    public var resourceKind: ResourceKind {
        let v = spec.versions.first { $0.storage } ?? spec.versions.first { $0.served }
        return .custom(group: spec.group, version: v?.name ?? "v1", kind: spec.names.kind,
                       plural: spec.names.plural, namespaced: spec.scope == "Namespaced")
    }
}

public struct PodDisruptionBudget: KubeObject {
    public static var resourceKind: ResourceKind { .podDisruptionBudget }
    public struct Status: Codable, Hashable, Sendable {
        public var disruptionsAllowed: Int?
        public var currentHealthy: Int?
        public var desiredHealthy: Int?
        public var expectedPods: Int?
    }
    public struct Spec: Codable, Hashable, Sendable {
        public var selector: LabelSelector?
        public var minAvailable: JSONValue?
        public var maxUnavailable: JSONValue?
    }
    public var metadata: ObjectMeta
    public var spec: Spec?
    public var status: Status?
}
