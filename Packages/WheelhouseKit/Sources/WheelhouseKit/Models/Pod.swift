import Foundation

public struct ContainerPort: Codable, Hashable, Sendable {
    public var name: String?
    public var containerPort: Int
    public var `protocol`: String?
    public var hostPort: Int?
}

public struct EnvVar: Codable, Hashable, Sendable {
    public var name: String
    public var value: String?
    public var valueFrom: JSONValue?
}

public struct ResourceRequirements: Codable, Hashable, Sendable {
    public var requests: [String: Quantity]?
    public var limits: [String: Quantity]?
    public init(requests: [String: Quantity]? = nil, limits: [String: Quantity]? = nil) {
        self.requests = requests
        self.limits = limits
    }
}

public struct VolumeMount: Codable, Hashable, Sendable {
    public var name: String
    public var mountPath: String
    public var readOnly: Bool?
    public var subPath: String?
}

public struct Probe: Codable, Hashable, Sendable {
    public var httpGet: JSONValue?
    public var tcpSocket: JSONValue?
    public var exec: JSONValue?
    public var grpc: JSONValue?
    public var initialDelaySeconds: Int?
    public var periodSeconds: Int?
    public var timeoutSeconds: Int?
    public var failureThreshold: Int?
    public var successThreshold: Int?
}

public struct Container: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var image: String?
    public var command: [String]?
    public var args: [String]?
    @Lenient public var ports: [ContainerPort]
    @Lenient public var env: [EnvVar]
    public var envFrom: [JSONValue]?
    public var resources: ResourceRequirements?
    @Lenient public var volumeMounts: [VolumeMount]
    public var livenessProbe: Probe?
    public var readinessProbe: Probe?
    public var startupProbe: Probe?
    public var imagePullPolicy: String?
    public var id: String { name }

    public init(name: String, image: String? = nil, ports: [ContainerPort] = [], resources: ResourceRequirements? = nil) {
        self.name = name
        self.image = image
        self.ports = ports
        self.env = []
        self.volumeMounts = []
        self.resources = resources
    }
}

public struct Toleration: Codable, Hashable, Sendable {
    public var key: String?
    public var `operator`: String?
    public var value: String?
    public var effect: String?
    public var tolerationSeconds: Int?
}

public struct Volume: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var persistentVolumeClaim: PVCSource?
    public var configMap: NamedSource?
    public var secret: SecretSource?
    public var emptyDir: JSONValue?
    public var hostPath: JSONValue?
    public var projected: JSONValue?
    public var id: String { name }

    public struct PVCSource: Codable, Hashable, Sendable { public var claimName: String }
    public struct NamedSource: Codable, Hashable, Sendable { public var name: String? }
    public struct SecretSource: Codable, Hashable, Sendable { public var secretName: String? }

    /// Short human description of the volume source.
    public var sourceDescription: String {
        if let c = persistentVolumeClaim { return "PVC \(c.claimName)" }
        if let c = configMap { return "ConfigMap \(c.name ?? "")" }
        if let s = secret { return "Secret \(s.secretName ?? "")" }
        if emptyDir != nil { return "emptyDir" }
        if hostPath != nil { return "hostPath" }
        if projected != nil { return "projected" }
        return "other"
    }
}

public struct PodSpec: Codable, Hashable, Sendable {
    @Lenient public var containers: [Container]
    @Lenient public var initContainers: [Container]
    @Lenient public var volumes: [Volume]
    public var nodeName: String?
    @Lenient public var nodeSelector: [String: String]
    public var serviceAccountName: String?
    public var restartPolicy: String?
    public var priority: Int?
    public var priorityClassName: String?
    public var hostNetwork: Bool?
    @Lenient public var tolerations: [Toleration]
    public var terminationGracePeriodSeconds: Int?
    public var imagePullSecrets: [JSONValue]?

    public init(containers: [Container] = [], nodeName: String? = nil) {
        self.containers = containers
        self.initContainers = []
        self.volumes = []
        self.nodeName = nodeName
        self.nodeSelector = [:]
        self.tolerations = []
    }
}

public struct ContainerState: Codable, Hashable, Sendable {
    public struct Waiting: Codable, Hashable, Sendable { public var reason: String?; public var message: String? }
    public struct Running: Codable, Hashable, Sendable { public var startedAt: Date? }
    public struct Terminated: Codable, Hashable, Sendable {
        public var exitCode: Int
        public var signal: Int?
        public var reason: String?
        public var message: String?
        public var startedAt: Date?
        public var finishedAt: Date?
        public var containerID: String?
    }
    public var waiting: Waiting?
    public var running: Running?
    public var terminated: Terminated?

    public init(waiting: Waiting? = nil, running: Running? = nil, terminated: Terminated? = nil) {
        self.waiting = waiting
        self.running = running
        self.terminated = terminated
    }
}

public struct ContainerStatus: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var ready: Bool
    public var restartCount: Int
    public var image: String?
    public var imageID: String?
    public var containerID: String?
    public var started: Bool?
    public var state: ContainerState?
    public var lastState: ContainerState?
    public var id: String { name }
}

public struct PodIP: Codable, Hashable, Sendable { public var ip: String }

public struct PodStatus: Codable, Hashable, Sendable {
    public var phase: String?
    public var reason: String?
    public var message: String?
    public var podIP: String?
    @Lenient public var podIPs: [PodIP]
    public var hostIP: String?
    public var startTime: Date?
    public var qosClass: String?
    public var nominatedNodeName: String?
    @Lenient public var conditions: [Condition]
    @Lenient public var containerStatuses: [ContainerStatus]
    @Lenient public var initContainerStatuses: [ContainerStatus]
    @Lenient public var ephemeralContainerStatuses: [ContainerStatus]

    public init(phase: String? = nil) {
        self.phase = phase
        self.podIPs = []
        self.conditions = []
        self.containerStatuses = []
        self.initContainerStatuses = []
        self.ephemeralContainerStatuses = []
    }
}

public struct Pod: KubeObject {
    public static var resourceKind: ResourceKind { .pod }
    public var metadata: ObjectMeta
    public var spec: PodSpec
    public var status: PodStatus?

    public var restartCount: Int { (status?.containerStatuses ?? []).reduce(0) { $0 + $1.restartCount } }
    public var readyContainers: Int { (status?.containerStatuses ?? []).filter(\.ready).count }
    public var totalContainers: Int { spec.containers.count }
}

// MARK: - Pod template (shared by controllers)

public struct PodTemplateSpec: Codable, Hashable, Sendable {
    public var metadata: ObjectMeta?
    public var spec: PodSpec
}
