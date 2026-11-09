import Foundation

/// `namespace/name` of a Secret named by `imagePullSecrets`.
public struct PullSecretRef: Hashable, Sendable {
    public var namespace: String
    public var name: String
    public init(namespace: String, name: String) {
        self.namespace = namespace
        self.name = name
    }
}

/// An image running in one cluster, with the workloads that run it.
public struct ImageUse: Hashable, Sendable {
    public var reference: ImageReference
    public var clusterID: ClusterID
    public var workloads: [TrivyOperator.WorkloadKey]
    public var pullSecrets: [PullSecretRef]
}

/// The image set of a local scan (ARCHITECTURE-MAC §6.1): the running pods' `status.containerStatuses[].imageID` (a digest), or the
/// tag when there is none (marked mutable), deduplicated across pods and clusters. Pure.
public enum ImageInventory {
    /// Images of running pods of one cluster.
    public static func build(pods: [JSONValue], clusterID: ClusterID) -> [ImageUse] {
        var order: [String] = []
        var uses: [String: ImageUse] = [:]
        for pod in pods {
            let phase = pod.value(at: "status.phase")?.stringValue ?? ""
            guard phase == "Running" || phase == "Pending" else { continue }
            let namespace = pod.value(at: "metadata.namespace")?.stringValue ?? ""
            let workload = owner(of: pod, namespace: namespace)
            let secrets = (pod.value(at: "spec.imagePullSecrets")?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }.map { PullSecretRef(namespace: namespace, name: $0) }
            for status in pod.value(at: "status.containerStatuses")?.arrayValue ?? [] {
                guard let image = status["image"]?.stringValue,
                      let ref = ImageReference.forContainer(image: image, imageID: status["imageID"]?.stringValue) else { continue }
                let key = ref.scanTarget
                if uses[key] == nil {
                    order.append(key)
                    uses[key] = ImageUse(reference: ref, clusterID: clusterID, workloads: [], pullSecrets: [])
                }
                if let workload, !(uses[key]?.workloads.contains(workload) ?? true) { uses[key]?.workloads.append(workload) }
                for s in secrets where !(uses[key]?.pullSecrets.contains(s) ?? true) { uses[key]?.pullSecrets.append(s) }
            }
        }
        return order.compactMap { uses[$0] }
    }

    /// One entry per scan target; the clusters that run it, in the order they were given.
    public struct Merged: Hashable, Sendable {
        public var reference: ImageReference
        public var clusters: [ClusterID]
        public var workloads: [ClusterID: [TrivyOperator.WorkloadKey]]
    }

    public static func merge(_ uses: [ImageUse]) -> [Merged] {
        var order: [String] = []
        var merged: [String: Merged] = [:]
        for u in uses {
            let key = u.reference.scanTarget
            if merged[key] == nil {
                order.append(key)
                merged[key] = Merged(reference: u.reference, clusters: [], workloads: [:])
            }
            if !(merged[key]?.clusters.contains(u.clusterID) ?? true) { merged[key]?.clusters.append(u.clusterID) }
            merged[key]?.workloads[u.clusterID, default: []] += u.workloads
        }
        return order.compactMap { merged[$0] }
    }

    private static func owner(of pod: JSONValue, namespace: String) -> TrivyOperator.WorkloadKey? {
        let owners = pod.value(at: "metadata.ownerReferences")?.arrayValue ?? []
        if let o = owners.first(where: { $0["controller"]?.boolValue == true }) ?? owners.first, let kind = o["kind"]?.stringValue, let name = o["name"]?.stringValue {
            let (k, n) = TrivyOperator.logicalOwner(kind: kind, name: name)
            return TrivyOperator.WorkloadKey(namespace: namespace, kind: k, name: n)
        }
        guard let name = pod.value(at: "metadata.name")?.stringValue else { return nil }
        return TrivyOperator.WorkloadKey(namespace: namespace, kind: "Pod", name: name)
    }
}
