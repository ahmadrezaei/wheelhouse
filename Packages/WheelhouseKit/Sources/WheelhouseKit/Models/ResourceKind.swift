import Foundation

public enum ResourceSection: String, Codable, CaseIterable, Sendable, Identifiable {
    case workloads, networking, config, storage, cluster, access, custom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .workloads: "Workloads"
        case .networking: "Networking"
        case .config: "Config"
        case .storage: "Storage"
        case .cluster: "Cluster"
        case .access: "Access"
        case .custom: "Custom Resources"
        }
    }
    public var symbol: String {
        switch self {
        case .workloads: "square.stack.3d.up"
        case .networking: "point.3.connected.trianglepath.dotted"
        case .config: "doc.plaintext"
        case .storage: "externaldrive"
        case .cluster: "server.rack"
        case .access: "lock.shield"
        case .custom: "puzzlepiece.extension"
        }
    }
}

/// Describes one Kubernetes API resource and knows how to build REST paths for it.
public struct ResourceKind: Hashable, Codable, Sendable, Identifiable {
    public var kind: String
    public var plural: String
    public var group: String
    public var version: String
    public var namespaced: Bool
    public var symbol: String
    public var displayName: String
    public var section: ResourceSection

    public init(kind: String, plural: String, group: String, version: String, namespaced: Bool,
                symbol: String, displayName: String? = nil, section: ResourceSection) {
        self.kind = kind
        self.plural = plural
        self.group = group
        self.version = version
        self.namespaced = namespaced
        self.symbol = symbol
        self.displayName = displayName ?? kind
        self.section = section
    }

    private enum CodingKeys: String, CodingKey { case kind, plural, group, version, namespaced, symbol, displayName, section }

    /// Persisted workspaces reference a kind by identity (group, version, kind, plural, namespaced). The cosmetic fields are
    /// encoded as before but are optional when decoding, so a later change to them never orphans a saved pane.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        plural = try c.decode(String.self, forKey: .plural)
        group = try c.decode(String.self, forKey: .group)
        version = try c.decode(String.self, forKey: .version)
        namespaced = try c.decode(Bool.self, forKey: .namespaced)
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "cube.transparent"
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? kind
        section = (try? c.decodeIfPresent(ResourceSection.self, forKey: .section)) ?? .custom
    }

    /// Stable identifier, e.g. `apps/v1/deployments` or `v1/pods`.
    public var id: String { group.isEmpty ? "\(version)/\(plural)" : "\(group)/\(version)/\(plural)" }
    public var apiVersion: String { group.isEmpty ? version : "\(group)/\(version)" }
    public var singularDisplayName: String { kind }

    // MARK: REST paths

    public var apiRoot: String { group.isEmpty ? "/api/\(version)" : "/apis/\(group)/\(version)" }

    /// `/apis/apps/v1/namespaces/ns/deployments` or cluster-wide when `namespace` is nil.
    public func collectionPath(namespace: String? = nil) -> String {
        if namespaced, let namespace {
            return "\(apiRoot)/namespaces/\(Self.escape(namespace))/\(plural)"
        }
        return "\(apiRoot)/\(plural)"
    }

    public func itemPath(name: String, namespace: String? = nil, subresource: String? = nil) -> String {
        var path = "\(collectionPath(namespace: namespace))/\(Self.escape(name))"
        if let subresource { path += "/\(subresource)" }
        return path
    }

    static func escape(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? component
    }

    /// Builds a kind from a discovered API resource (used for CRDs / custom resources).
    public static func custom(group: String, version: String, kind: String, plural: String, namespaced: Bool) -> ResourceKind {
        ResourceKind(kind: kind, plural: plural, group: group, version: version, namespaced: namespaced,
                     symbol: "cube.transparent", displayName: kind, section: .custom)
    }
}

// MARK: - Registry

public extension ResourceKind {
    static let unknown = ResourceKind(kind: "Unknown", plural: "unknowns", group: "", version: "v1", namespaced: false, symbol: "cube.transparent", section: .custom)

    // Workloads
    static let pod = ResourceKind(kind: "Pod", plural: "pods", group: "", version: "v1", namespaced: true, symbol: "cube", displayName: "Pods", section: .workloads)
    static let deployment = ResourceKind(kind: "Deployment", plural: "deployments", group: "apps", version: "v1", namespaced: true, symbol: "square.stack.3d.up", displayName: "Deployments", section: .workloads)
    static let replicaSet = ResourceKind(kind: "ReplicaSet", plural: "replicasets", group: "apps", version: "v1", namespaced: true, symbol: "square.on.square", displayName: "ReplicaSets", section: .workloads)
    static let statefulSet = ResourceKind(kind: "StatefulSet", plural: "statefulsets", group: "apps", version: "v1", namespaced: true, symbol: "cylinder.split.1x2", displayName: "StatefulSets", section: .workloads)
    static let daemonSet = ResourceKind(kind: "DaemonSet", plural: "daemonsets", group: "apps", version: "v1", namespaced: true, symbol: "circle.grid.3x3", displayName: "DaemonSets", section: .workloads)
    static let job = ResourceKind(kind: "Job", plural: "jobs", group: "batch", version: "v1", namespaced: true, symbol: "checkmark.square", displayName: "Jobs", section: .workloads)
    static let cronJob = ResourceKind(kind: "CronJob", plural: "cronjobs", group: "batch", version: "v1", namespaced: true, symbol: "calendar.badge.clock", displayName: "CronJobs", section: .workloads)
    // Networking
    static let service = ResourceKind(kind: "Service", plural: "services", group: "", version: "v1", namespaced: true, symbol: "point.3.connected.trianglepath.dotted", displayName: "Services", section: .networking)
    static let ingress = ResourceKind(kind: "Ingress", plural: "ingresses", group: "networking.k8s.io", version: "v1", namespaced: true, symbol: "arrow.right.to.line", displayName: "Ingresses", section: .networking)
    static let networkPolicy = ResourceKind(kind: "NetworkPolicy", plural: "networkpolicies", group: "networking.k8s.io", version: "v1", namespaced: true, symbol: "shield.lefthalf.filled", displayName: "NetworkPolicies", section: .networking)
    static let endpoints = ResourceKind(kind: "Endpoints", plural: "endpoints", group: "", version: "v1", namespaced: true, symbol: "dot.radiowaves.left.and.right", displayName: "Endpoints", section: .networking)
    static let endpointSlice = ResourceKind(kind: "EndpointSlice", plural: "endpointslices", group: "discovery.k8s.io", version: "v1", namespaced: true, symbol: "dot.radiowaves.left.and.right", displayName: "EndpointSlices", section: .networking)
    // Config
    static let configMap = ResourceKind(kind: "ConfigMap", plural: "configmaps", group: "", version: "v1", namespaced: true, symbol: "doc.plaintext", displayName: "ConfigMaps", section: .config)
    static let secret = ResourceKind(kind: "Secret", plural: "secrets", group: "", version: "v1", namespaced: true, symbol: "key", displayName: "Secrets", section: .config)
    // Storage
    static let persistentVolume = ResourceKind(kind: "PersistentVolume", plural: "persistentvolumes", group: "", version: "v1", namespaced: false, symbol: "externaldrive", displayName: "PersistentVolumes", section: .storage)
    static let persistentVolumeClaim = ResourceKind(kind: "PersistentVolumeClaim", plural: "persistentvolumeclaims", group: "", version: "v1", namespaced: true, symbol: "cylinder", displayName: "PersistentVolumeClaims", section: .storage)
    static let storageClass = ResourceKind(kind: "StorageClass", plural: "storageclasses", group: "storage.k8s.io", version: "v1", namespaced: false, symbol: "tray.2", displayName: "StorageClasses", section: .storage)
    // Cluster
    static let node = ResourceKind(kind: "Node", plural: "nodes", group: "", version: "v1", namespaced: false, symbol: "server.rack", displayName: "Nodes", section: .cluster)
    static let namespace = ResourceKind(kind: "Namespace", plural: "namespaces", group: "", version: "v1", namespaced: false, symbol: "folder", displayName: "Namespaces", section: .cluster)
    static let event = ResourceKind(kind: "Event", plural: "events", group: "", version: "v1", namespaced: true, symbol: "bolt", displayName: "Events", section: .cluster)
    static let eventsV1 = ResourceKind(kind: "Event", plural: "events", group: "events.k8s.io", version: "v1", namespaced: true, symbol: "bolt", displayName: "Events", section: .cluster)
    static let customResourceDefinition = ResourceKind(kind: "CustomResourceDefinition", plural: "customresourcedefinitions", group: "apiextensions.k8s.io", version: "v1", namespaced: false, symbol: "puzzlepiece.extension", displayName: "CRDs", section: .cluster)
    // Access
    static let serviceAccount = ResourceKind(kind: "ServiceAccount", plural: "serviceaccounts", group: "", version: "v1", namespaced: true, symbol: "person.crop.circle", displayName: "ServiceAccounts", section: .access)
    static let role = ResourceKind(kind: "Role", plural: "roles", group: "rbac.authorization.k8s.io", version: "v1", namespaced: true, symbol: "lock.shield", displayName: "Roles", section: .access)
    static let clusterRole = ResourceKind(kind: "ClusterRole", plural: "clusterroles", group: "rbac.authorization.k8s.io", version: "v1", namespaced: false, symbol: "lock.shield", displayName: "ClusterRoles", section: .access)
    static let roleBinding = ResourceKind(kind: "RoleBinding", plural: "rolebindings", group: "rbac.authorization.k8s.io", version: "v1", namespaced: true, symbol: "link", displayName: "RoleBindings", section: .access)
    static let clusterRoleBinding = ResourceKind(kind: "ClusterRoleBinding", plural: "clusterrolebindings", group: "rbac.authorization.k8s.io", version: "v1", namespaced: false, symbol: "link", displayName: "ClusterRoleBindings", section: .access)

    // API-only kinds (not shown in section lists)
    static let nodeMetrics = ResourceKind(kind: "NodeMetrics", plural: "nodes", group: "metrics.k8s.io", version: "v1beta1", namespaced: false, symbol: "gauge", section: .cluster)
    static let podMetrics = ResourceKind(kind: "PodMetrics", plural: "pods", group: "metrics.k8s.io", version: "v1beta1", namespaced: true, symbol: "gauge", section: .workloads)
    static let selfSubjectAccessReview = ResourceKind(kind: "SelfSubjectAccessReview", plural: "selfsubjectaccessreviews", group: "authorization.k8s.io", version: "v1", namespaced: false, symbol: "hand.raised", section: .access)
    static let selfSubjectRulesReview = ResourceKind(kind: "SelfSubjectRulesReview", plural: "selfsubjectrulesreviews", group: "authorization.k8s.io", version: "v1", namespaced: false, symbol: "hand.raised", section: .access)
    static let podDisruptionBudget = ResourceKind(kind: "PodDisruptionBudget", plural: "poddisruptionbudgets", group: "policy", version: "v1", namespaced: true, symbol: "shield", displayName: "PodDisruptionBudgets", section: .workloads)
    static let horizontalPodAutoscaler = ResourceKind(kind: "HorizontalPodAutoscaler", plural: "horizontalpodautoscalers", group: "autoscaling", version: "v2", namespaced: true, symbol: "arrow.up.and.down", displayName: "HorizontalPodAutoscalers", section: .workloads)

    /// Every built-in kind shown in the Resources tab, in display order.
    static let builtIn: [ResourceKind] = [
        .pod, .deployment, .statefulSet, .daemonSet, .replicaSet, .job, .cronJob,
        .service, .ingress, .networkPolicy, .endpoints, .endpointSlice,
        .configMap, .secret,
        .persistentVolume, .persistentVolumeClaim, .storageClass,
        .node, .namespace, .event, .customResourceDefinition,
        .serviceAccount, .role, .clusterRole, .roleBinding, .clusterRoleBinding,
    ]

    static func builtIn(in section: ResourceSection) -> [ResourceKind] { builtIn.filter { $0.section == section } }

    /// Looks up a built-in kind by `Kind` (case-insensitive) or plural name, e.g. from deep links.
    static func lookup(_ name: String) -> ResourceKind? {
        let n = name.lowercased()
        return (builtIn + [podDisruptionBudget, horizontalPodAutoscaler]).first { $0.kind.lowercased() == n || $0.plural == n }
    }
}
