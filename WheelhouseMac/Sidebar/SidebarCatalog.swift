import Foundation
import WheelhouseKit

/// The sidebar group catalogue (DESIGN-MAC §3.6, ARCHITECTURE-MAC §12.5): group order, glyphs and the `ResourceKind`s per group.
/// Declared in M1a. The tree (`SidebarTree`, discovery-driven kinds, RBAC hiding, counts from running stores) is M1b. Feature
/// groups (Chart Room, Tides, Survey) supply their nodes through their `Feature` stub's `sidebarNodes`.
enum SidebarGroupID: String, CaseIterable, Hashable, Sendable {
    case overview, workloads, config, network, storage, namespaces, events
    case chartRoom, tides, survey
    case accessControl, customResources
}

/// One kind row in a group.
struct SidebarKindEntry: Hashable, Sendable {
    var kind: ResourceKind
    /// Shown only when at least one object exists (ReplicationControllers).
    var onlyWhenAnyExist = false
    /// Shown only when the cluster serves the API (Gateway API kinds); every catalogue kind is also hidden when unserved.
    var requiresServed = true
    var title: String { kind.displayName }
}

struct SidebarGroup: Identifiable, Hashable, Sendable {
    var id: SidebarGroupID
    var title: String
    var symbol: String
    /// "Helm" next to Chart Room, "GitOps" next to Tides.
    var secondaryLabel: String?
    /// A group row that opens a pane itself and has no children (Overview, Namespaces, Events).
    var isLeaf = false
    var kinds: [SidebarKindEntry] = []
    /// The feature that supplies this group's child nodes.
    var feature: FeatureID?
    /// A "workload summary" row at the top of the group (Workloads only).
    var hasSummaryRow = false
    /// Wheelhouse-owned rows that are not API kinds (Port Forwards under Network).
    var extraRows: [SidebarExtraRow] = []
}

enum SidebarExtraRow: String, Hashable, Sendable { case portForwards, crdDefinitions }

enum SidebarCatalog {
    // Kinds that the Kit does not declare as statics. Declared here so the catalogue is complete.
    static let replicationController = ResourceKind(kind: "ReplicationController", plural: "replicationcontrollers", group: "", version: "v1", namespaced: true, symbol: "square.on.square.dashed", displayName: "ReplicationControllers", section: .workloads)
    static let resourceQuota = ResourceKind(kind: "ResourceQuota", plural: "resourcequotas", group: "", version: "v1", namespaced: true, symbol: "chart.pie", displayName: "ResourceQuotas", section: .config)
    static let limitRange = ResourceKind(kind: "LimitRange", plural: "limitranges", group: "", version: "v1", namespaced: true, symbol: "ruler", displayName: "LimitRanges", section: .config)
    static let priorityClass = ResourceKind(kind: "PriorityClass", plural: "priorityclasses", group: "scheduling.k8s.io", version: "v1", namespaced: false, symbol: "arrow.up.arrow.down", displayName: "PriorityClasses", section: .config)
    static let runtimeClass = ResourceKind(kind: "RuntimeClass", plural: "runtimeclasses", group: "node.k8s.io", version: "v1", namespaced: false, symbol: "gearshape.2", displayName: "RuntimeClasses", section: .config)
    static let lease = ResourceKind(kind: "Lease", plural: "leases", group: "coordination.k8s.io", version: "v1", namespaced: true, symbol: "clock", displayName: "Leases", section: .config)
    static let mutatingWebhook = ResourceKind(kind: "MutatingWebhookConfiguration", plural: "mutatingwebhookconfigurations", group: "admissionregistration.k8s.io", version: "v1", namespaced: false, symbol: "wand.and.stars", displayName: "Mutating Webhook Configurations", section: .config)
    static let validatingWebhook = ResourceKind(kind: "ValidatingWebhookConfiguration", plural: "validatingwebhookconfigurations", group: "admissionregistration.k8s.io", version: "v1", namespaced: false, symbol: "checkmark.shield", displayName: "Validating Webhook Configurations", section: .config)
    static let ingressClass = ResourceKind(kind: "IngressClass", plural: "ingressclasses", group: "networking.k8s.io", version: "v1", namespaced: false, symbol: "arrow.right.to.line.compact", displayName: "IngressClasses", section: .networking)
    static let volumeAttachment = ResourceKind(kind: "VolumeAttachment", plural: "volumeattachments", group: "storage.k8s.io", version: "v1", namespaced: false, symbol: "paperclip", displayName: "VolumeAttachments", section: .storage)
    static let csiDriver = ResourceKind(kind: "CSIDriver", plural: "csidrivers", group: "storage.k8s.io", version: "v1", namespaced: false, symbol: "externaldrive.badge.checkmark", displayName: "CSI Drivers", section: .storage)

    private static func gateway(_ kind: String, _ plural: String, group: String = "gateway.networking.k8s.io", version: String = "v1") -> ResourceKind {
        ResourceKind(kind: kind, plural: plural, group: group, version: version, namespaced: true, symbol: "signpost.right.and.left", displayName: kind + "s", section: .networking)
    }
    /// Gateway API kinds, each shown only when its CRD is served.
    static let gatewayKinds: [ResourceKind] = [
        ResourceKind(kind: "GatewayClass", plural: "gatewayclasses", group: "gateway.networking.k8s.io", version: "v1", namespaced: false, symbol: "signpost.right.and.left", displayName: "GatewayClasses", section: .networking),
        gateway("Gateway", "gateways"),
        gateway("HTTPRoute", "httproutes"),
        gateway("GRPCRoute", "grpcroutes"),
        gateway("TLSRoute", "tlsroutes", version: "v1alpha2"),
        gateway("TCPRoute", "tcproutes", version: "v1alpha2"),
        gateway("ReferenceGrant", "referencegrants", version: "v1beta1"),
    ]

    /// The groups in their fixed order. Kinds whose API is not served are never shown (the tree filters by discovery).
    static let groups: [SidebarGroup] = [
        SidebarGroup(id: .overview, title: "Overview", symbol: "gauge.with.dots.needle.67percent", isLeaf: true),
        SidebarGroup(id: .workloads, title: "Workloads", symbol: "square.stack.3d.up", kinds: [
            SidebarKindEntry(kind: .pod), SidebarKindEntry(kind: .deployment), SidebarKindEntry(kind: .daemonSet), SidebarKindEntry(kind: .statefulSet),
            SidebarKindEntry(kind: .replicaSet), SidebarKindEntry(kind: replicationController, onlyWhenAnyExist: true),
            SidebarKindEntry(kind: .job), SidebarKindEntry(kind: .cronJob),
        ], hasSummaryRow: true),
        SidebarGroup(id: .config, title: "Config", symbol: "doc.plaintext", kinds: [
            .configMap, .secret, resourceQuota, limitRange, .horizontalPodAutoscaler, .podDisruptionBudget, priorityClass, runtimeClass, lease,
            mutatingWebhook, validatingWebhook,
        ].map { SidebarKindEntry(kind: $0) }),
        SidebarGroup(id: .network, title: "Network", symbol: "point.3.connected.trianglepath.dotted",
                     kinds: ([ResourceKind.service, .endpointSlice, .ingress, ingressClass, .networkPolicy] + gatewayKinds).map { SidebarKindEntry(kind: $0) },
                     extraRows: [.portForwards]),
        SidebarGroup(id: .storage, title: "Storage", symbol: "externaldrive", kinds: [
            .persistentVolumeClaim, .persistentVolume, .storageClass, volumeAttachment, csiDriver,
        ].map { SidebarKindEntry(kind: $0) }),
        SidebarGroup(id: .namespaces, title: "Namespaces", symbol: "folder", isLeaf: true, kinds: [SidebarKindEntry(kind: .namespace)]),
        SidebarGroup(id: .events, title: "Events", symbol: "bolt", isLeaf: true, kinds: [SidebarKindEntry(kind: .event)]),
        SidebarGroup(id: .chartRoom, title: "Chart Room", symbol: "shippingbox", secondaryLabel: "Helm", feature: .chartRoom),
        SidebarGroup(id: .tides, title: "Tides", symbol: "water.waves", secondaryLabel: "GitOps", feature: .tides),
        SidebarGroup(id: .survey, title: "Survey", symbol: "binoculars", feature: .survey),
        SidebarGroup(id: .accessControl, title: "Access Control", symbol: "lock.shield", kinds: [
            .serviceAccount, .role, .clusterRole, .roleBinding, .clusterRoleBinding,
        ].map { SidebarKindEntry(kind: $0) }),
        SidebarGroup(id: .customResources, title: "Custom Resources", symbol: "puzzlepiece.extension", extraRows: [.crdDefinitions]),
    ]

    static func group(_ id: SidebarGroupID) -> SidebarGroup { groups.first { $0.id == id }! }

    /// Every catalogue kind, in display order (used to compute which served kinds are "covered" so Custom Resources lists the rest).
    static var allKinds: [ResourceKind] { groups.flatMap { $0.kinds.map(\.kind) } }

    /// Lower-cased names a filter matches for a kind: display name, singular, plural and the kubectl short names.
    static func filterTerms(for kind: ResourceKind) -> [String] {
        var terms = [kind.displayName.lowercased(), kind.kind.lowercased(), kind.plural]
        if let short = shortNames[kind.plural] { terms.append(contentsOf: short) }
        return terms
    }

    /// kubectl short names for the catalogue kinds.
    static let shortNames: [String: [String]] = [
        "pods": ["po"], "deployments": ["deploy"], "daemonsets": ["ds"], "statefulsets": ["sts"], "replicasets": ["rs"],
        "replicationcontrollers": ["rc"], "cronjobs": ["cj"], "configmaps": ["cm"], "resourcequotas": ["quota"], "limitranges": ["limits"],
        "horizontalpodautoscalers": ["hpa"], "poddisruptionbudgets": ["pdb"], "priorityclasses": ["pc"], "services": ["svc"],
        "endpointslices": ["eps"], "endpoints": ["ep"], "ingresses": ["ing"], "networkpolicies": ["netpol"],
        "persistentvolumeclaims": ["pvc"], "persistentvolumes": ["pv"], "storageclasses": ["sc"], "namespaces": ["ns"],
        "events": ["ev"], "serviceaccounts": ["sa"], "customresourcedefinitions": ["crd", "crds"],
    ]
}
