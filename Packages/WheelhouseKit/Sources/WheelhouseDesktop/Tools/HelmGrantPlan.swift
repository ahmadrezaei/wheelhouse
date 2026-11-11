#if os(macOS)
import Foundation
import WheelhouseKit

/// The exact set `S` of objects a helm run may change after its review (ARCHITECTURE-MAC section 5.2, flow step 5), and the warnings the
/// review shows next to the diff. Pure: the review flow gives it the release records and the dry-run output.
public struct HelmGrantPlan: Sendable, Equatable {
    public var objects: Set<GrantedObject>
    /// Hooks that will run, for the review sheet.
    public var hooks: [HelmRelease.Hook]
    public var warnings: [String]

    public init(objects: Set<GrantedObject>, hooks: [HelmRelease.Hook], warnings: [String]) {
        self.objects = objects
        self.hooks = hooks
        self.warnings = warnings
    }

    /// What a plan is built from. Every field is optional: an install has no current release, a rollback has no rendered one.
    public struct Inputs: Sendable {
        public var operation: HelmOperation
        /// The dry-run result of an install or upgrade; for a rollback, the revision being restored.
        public var next: HelmRelease?
        /// The release as it is now (upgrade, rollback, uninstall).
        public var current: HelmRelease?
        /// `helm show crds` output (install and upgrade, unless the CRDs are skipped).
        public var crdsYAML: String?
        public var skipCRDs: Bool
        public var discovery: DiscoveryInfo?
        public init(operation: HelmOperation, next: HelmRelease? = nil, current: HelmRelease? = nil, crdsYAML: String? = nil, skipCRDs: Bool = false,
                    discovery: DiscoveryInfo? = nil) {
            self.operation = operation
            self.next = next
            self.current = current
            self.crdsYAML = crdsYAML
            self.skipCRDs = skipCRDs
            self.discovery = discovery
        }
    }

    public static func build(_ input: Inputs) -> HelmGrantPlan {
        let op = input.operation
        var objects = Set<GrantedObject>()
        func add(manifest: String) {
            for object in HelmManifest.objects(in: manifest) { objects.insert(grant(for: object, releaseNamespace: op.namespace, discovery: input.discovery)) }
        }
        for release in [input.next, input.current].compactMap({ $0 }) {
            add(manifest: release.manifest)
            for hook in release.hooks { add(manifest: hook.manifest) }
        }
        let hooks = (input.next ?? input.current)?.hooks ?? []
        if !input.skipCRDs, let crds = input.crdsYAML { add(manifest: crds) }
        // helm's own records: a new revision, status updates of old ones, and `--history-max` pruning.
        let prefix = "sh.helm.release.v1.\(op.release).v"
        objects.insert(GrantedObject(resource: "secrets", namespace: op.namespace, namePrefix: prefix))
        objects.insert(GrantedObject(resource: "configmaps", namespace: op.namespace, namePrefix: prefix))
        if case .install(_, _, _, let namespace, true) = op { objects.insert(GrantedObject(resource: "namespaces", name: namespace)) }
        return HelmGrantPlan(objects: objects, hooks: hooks, warnings: warnings(from: input.current, to: input.next, op: op))
    }

    static func grant(for object: HelmManifestObject, releaseNamespace: String, discovery: DiscoveryInfo?) -> GrantedObject {
        let kind = HelmManifest.resourceKind(for: object, discovery: discovery)
        let namespace = kind.namespaced ? (object.namespace ?? releaseNamespace) : nil
        let hasName = !(object.value.value(at: "metadata.name")?.stringValue ?? "").isEmpty
        return hasName
            ? GrantedObject(group: kind.group, resource: kind.plural, namespace: namespace, name: object.name)
            : GrantedObject(group: kind.group, resource: kind.plural, namespace: namespace, generateNamePrefix: object.name)
    }

    // MARK: Warnings (ARCHITECTURE-MAC section 5.3)

    static func warnings(from old: HelmRelease?, to new: HelmRelease?, op: HelmOperation) -> [String] {
        var out: [String] = []
        let oldObjects = old.map { HelmManifest.objects(in: $0.manifest) } ?? []
        let newObjects = new.map { HelmManifest.objects(in: $0.manifest) } ?? []
        let newIDs = Set(newObjects.map(\.id))
        let removing: [HelmManifestObject]
        switch op {
        case .uninstall: removing = oldObjects
        case .install: removing = []
        case .upgrade, .rollback: removing = oldObjects.filter { !newIDs.contains($0.id) }
        }
        for object in removing where object.kind == "PersistentVolumeClaim" {
            out.append("PersistentVolumeClaim \(object.name) will be deleted with its data.")
        }
        if case .uninstall = op {
            for object in oldObjects where object.kind == "StatefulSet" {
                let claims = object.value.value(at: "spec.volumeClaimTemplates")?.arrayValue?.compactMap { $0.value(at: "metadata.name")?.stringValue } ?? []
                if !claims.isEmpty { out.append("Persistent volume claims of StatefulSet \(object.name) (\(claims.joined(separator: ", "))) stay in the cluster.") }
            }
        }
        let oldByID = Dictionary(oldObjects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for object in newObjects {
            guard let before = oldByID[object.id] else { continue }
            func changed(_ path: String) -> Bool { before.value.value(at: path) != object.value.value(at: path) }
            switch object.kind {
            case "Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job":
                if changed("spec.selector") { out.append("\(object.kind) \(object.name): the selector changed, and it cannot be updated in place.") }
                if object.kind == "StatefulSet", changed("spec.volumeClaimTemplates") {
                    out.append("StatefulSet \(object.name): volumeClaimTemplates changed, and they cannot be updated in place.")
                }
            case "Service":
                if changed("spec.type") { out.append("Service \(object.name): the type changes from \(before.value.value(at: "spec.type")?.stringValue ?? "ClusterIP") to \(object.value.value(at: "spec.type")?.stringValue ?? "ClusterIP").") }
                if changed("spec.clusterIP") { out.append("Service \(object.name): spec.clusterIP changed, and it is immutable.") }
            default: break
            }
        }
        return out
    }
}
#endif
