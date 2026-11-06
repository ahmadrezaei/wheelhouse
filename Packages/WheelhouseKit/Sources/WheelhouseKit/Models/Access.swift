import Foundation

public struct ServiceAccount: KubeObject {
    public static var resourceKind: ResourceKind { .serviceAccount }
    public var metadata: ObjectMeta
    public var secrets: [ObjectReference]?
    public var imagePullSecrets: [ObjectReference]?
    public var automountServiceAccountToken: Bool?
}

public struct PolicyRule: Codable, Hashable, Sendable {
    @Lenient public var apiGroups: [String]
    @Lenient public var resources: [String]
    @Lenient public var verbs: [String]
    @Lenient public var resourceNames: [String]
    @Lenient public var nonResourceURLs: [String]
}

public struct Subject: Codable, Hashable, Sendable {
    public var kind: String
    public var name: String
    public var namespace: String?
    public var apiGroup: String?
}

public struct RoleRef: Codable, Hashable, Sendable {
    public var apiGroup: String
    public var kind: String
    public var name: String
}

public struct Role: KubeObject {
    public static var resourceKind: ResourceKind { .role }
    public var metadata: ObjectMeta
    @Lenient public var rules: [PolicyRule]
}

public struct ClusterRole: KubeObject {
    public static var resourceKind: ResourceKind { .clusterRole }
    public var metadata: ObjectMeta
    @Lenient public var rules: [PolicyRule]
    public var aggregationRule: JSONValue?
}

public struct RoleBinding: KubeObject {
    public static var resourceKind: ResourceKind { .roleBinding }
    public var metadata: ObjectMeta
    public var roleRef: RoleRef
    @Lenient public var subjects: [Subject]
}

public struct ClusterRoleBinding: KubeObject {
    public static var resourceKind: ResourceKind { .clusterRoleBinding }
    public var metadata: ObjectMeta
    public var roleRef: RoleRef
    @Lenient public var subjects: [Subject]
}
