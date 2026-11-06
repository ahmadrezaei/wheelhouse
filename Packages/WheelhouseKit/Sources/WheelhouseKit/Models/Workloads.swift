import Foundation

public struct DeploymentStrategy: Codable, Hashable, Sendable {
    public var type: String?
    public var rollingUpdate: JSONValue?
}

public struct Deployment: KubeObject {
    public static var resourceKind: ResourceKind { .deployment }
    public struct Spec: Codable, Hashable, Sendable {
        public var replicas: Int?
        public var selector: LabelSelector?
        public var template: PodTemplateSpec
        public var strategy: DeploymentStrategy?
        public var paused: Bool?
        public var minReadySeconds: Int?
        public var revisionHistoryLimit: Int?
    }
    public struct Status: Codable, Hashable, Sendable {
        public var observedGeneration: Int?
        public var replicas: Int?
        public var updatedReplicas: Int?
        public var readyReplicas: Int?
        public var availableReplicas: Int?
        public var unavailableReplicas: Int?
        @Lenient public var conditions: [Condition]
    }
    public var metadata: ObjectMeta
    public var spec: Spec
    public var status: Status?

    public var desiredReplicas: Int { spec.replicas ?? 1 }
    public var readyReplicas: Int { status?.readyReplicas ?? 0 }
    public var availableReplicas: Int { status?.availableReplicas ?? 0 }
    public var revision: String? { metadata.annotations["deployment.kubernetes.io/revision"] }
}

public struct ReplicaSet: KubeObject {
    public static var resourceKind: ResourceKind { .replicaSet }
    public struct Spec: Codable, Hashable, Sendable {
        public var replicas: Int?
        public var selector: LabelSelector?
        public var template: PodTemplateSpec?
    }
    public struct Status: Codable, Hashable, Sendable {
        public var replicas: Int?
        public var readyReplicas: Int?
        public var availableReplicas: Int?
        public var fullyLabeledReplicas: Int?
    }
    public var metadata: ObjectMeta
    public var spec: Spec
    public var status: Status?
    public var desiredReplicas: Int { spec.replicas ?? 1 }
    public var readyReplicas: Int { status?.readyReplicas ?? 0 }
    public var revision: String? { metadata.annotations["deployment.kubernetes.io/revision"] }
}

public struct StatefulSet: KubeObject {
    public static var resourceKind: ResourceKind { .statefulSet }
    public struct Spec: Codable, Hashable, Sendable {
        public var replicas: Int?
        public var selector: LabelSelector?
        public var template: PodTemplateSpec
        public var serviceName: String?
        public var podManagementPolicy: String?
        public var updateStrategy: JSONValue?
        public var volumeClaimTemplates: [JSONValue]?
    }
    public struct Status: Codable, Hashable, Sendable {
        public var replicas: Int?
        public var readyReplicas: Int?
        public var availableReplicas: Int?
        public var currentReplicas: Int?
        public var updatedReplicas: Int?
        public var currentRevision: String?
        public var updateRevision: String?
        @Lenient public var conditions: [Condition]
    }
    public var metadata: ObjectMeta
    public var spec: Spec
    public var status: Status?
    public var desiredReplicas: Int { spec.replicas ?? 1 }
    public var readyReplicas: Int { status?.readyReplicas ?? 0 }
}

public struct DaemonSet: KubeObject {
    public static var resourceKind: ResourceKind { .daemonSet }
    public struct Spec: Codable, Hashable, Sendable {
        public var selector: LabelSelector?
        public var template: PodTemplateSpec
        public var updateStrategy: JSONValue?
    }
    public struct Status: Codable, Hashable, Sendable {
        public var currentNumberScheduled: Int?
        public var desiredNumberScheduled: Int?
        public var numberReady: Int?
        public var numberAvailable: Int?
        public var numberMisscheduled: Int?
        public var updatedNumberScheduled: Int?
        public var numberUnavailable: Int?
        @Lenient public var conditions: [Condition]
    }
    public var metadata: ObjectMeta
    public var spec: Spec
    public var status: Status?
    public var desiredReplicas: Int { status?.desiredNumberScheduled ?? 0 }
    public var readyReplicas: Int { status?.numberReady ?? 0 }
}

public struct Job: KubeObject {
    public static var resourceKind: ResourceKind { .job }
    public struct Spec: Codable, Hashable, Sendable {
        public var completions: Int?
        public var parallelism: Int?
        public var backoffLimit: Int?
        public var suspend: Bool?
        public var activeDeadlineSeconds: Int?
        public var ttlSecondsAfterFinished: Int?
        public var selector: LabelSelector?
        public var template: PodTemplateSpec
    }
    public struct Status: Codable, Hashable, Sendable {
        public var active: Int?
        public var succeeded: Int?
        public var failed: Int?
        public var ready: Int?
        public var startTime: Date?
        public var completionTime: Date?
        @Lenient public var conditions: [Condition]
    }
    public var metadata: ObjectMeta
    public var spec: Spec
    public var status: Status?

    public var isFailed: Bool { status?.conditions.contains { $0.type == "Failed" && $0.isTrue } ?? false }
    public var isComplete: Bool { status?.conditions.contains { $0.type == "Complete" && $0.isTrue } ?? false }
    public var failureCondition: Condition? { status?.conditions.first { $0.type == "Failed" && $0.isTrue } }
}

public struct CronJob: KubeObject {
    public static var resourceKind: ResourceKind { .cronJob }
    public struct JobTemplate: Codable, Hashable, Sendable {
        public var metadata: ObjectMeta?
        public var spec: Job.Spec
    }
    public struct Spec: Codable, Hashable, Sendable {
        public var schedule: String
        public var timeZone: String?
        public var suspend: Bool?
        public var concurrencyPolicy: String?
        public var successfulJobsHistoryLimit: Int?
        public var failedJobsHistoryLimit: Int?
        public var jobTemplate: JobTemplate
    }
    public struct Status: Codable, Hashable, Sendable {
        @Lenient public var active: [ObjectReference]
        public var lastScheduleTime: Date?
        public var lastSuccessfulTime: Date?
    }
    public var metadata: ObjectMeta
    public var spec: Spec
    public var status: Status?
    public var isSuspended: Bool { spec.suspend ?? false }
}
