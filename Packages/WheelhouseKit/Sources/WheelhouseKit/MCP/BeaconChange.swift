import Foundation
import Synchronization

/// The change-request tools (ARCHITECTURE-MAC section 10.2). Names are the wire names.
public enum ChangeTool: String, CaseIterable, Sendable {
    case applyManifest = "request_apply_manifest"
    case patch = "request_patch"
    case scale = "request_scale"
    case restartRollout = "request_restart_rollout"
    case delete = "request_delete"
    case helmRollback = "request_helm_rollback"
    case gitopsSync = "request_gitops_sync"
}

/// A validated change request. It is a description: nothing here can reach a cluster. The app turns it into a confirmation sheet
/// whose action is the only thing that mutates.
public enum BeaconChangeRequest: Sendable, Equatable {
    case scale(kind: ResourceKind, name: String, namespace: String?, replicas: Int)
    case restartRollout(kind: ResourceKind, name: String, namespace: String?)
    case delete(kind: ResourceKind, name: String, namespace: String?)
    case patch(kind: ResourceKind, name: String, namespace: String?, patchType: String, body: JSONValue)
    case applyManifest(document: JSONValue, kind: ResourceKind, name: String, namespace: String?)
    case helmRollback(release: String, namespace: String, revision: Int?)
    case gitopsSync(controller: String, kind: String, name: String, namespace: String)

    public var tool: ChangeTool {
        switch self {
        case .scale: .scale
        case .restartRollout: .restartRollout
        case .delete: .delete
        case .patch: .patch
        case .applyManifest: .applyManifest
        case .helmRollback: .helmRollback
        case .gitopsSync: .gitopsSync
        }
    }

    public var namespace: String? {
        switch self {
        case .scale(_, _, let ns, _), .restartRollout(_, _, let ns), .delete(_, _, let ns), .patch(_, _, let ns, _, _), .applyManifest(_, _, _, let ns): ns
        case .helmRollback(_, let ns, _), .gitopsSync(_, _, _, let ns): ns
        }
    }

    /// `deployment/web`
    public var resource: String {
        switch self {
        case .scale(let k, let n, _, _), .restartRollout(let k, let n, _), .delete(let k, let n, _), .patch(let k, let n, _, _, _), .applyManifest(_, let k, let n, _):
            "\(k.kind.lowercased())/\(n)"
        case .helmRollback(let release, _, _): "helmrelease/\(release)"
        case .gitopsSync(_, let kind, let name, _): "\(kind.lowercased())/\(name)"
        }
    }

    /// The name to type on a typed confirmation.
    public var confirmationText: String { String(resource.split(separator: "/").last ?? "") }

    public var verb: String {
        switch self {
        case .scale: "Scale"
        case .restartRollout: "Restart Rollout"
        case .delete: "Delete"
        case .patch: "Apply Patch"
        case .applyManifest: "Apply"
        case .helmRollback: "Roll Back"
        case .gitopsSync: "Sync"
        }
    }

    public var isDestructive: Bool {
        switch self {
        case .delete, .helmRollback: true
        default: false
        }
    }

    /// One sentence for the sheet.
    public var summary: String {
        switch self {
        case .scale(_, _, _, let replicas): "Scale \(resource) to \(replicas) replicas."
        case .restartRollout: "Restart the rollout of \(resource)."
        case .delete: "Delete \(resource)."
        case .patch(_, _, _, let type, _): "Apply a \(type) patch to \(resource)."
        case .applyManifest: "Apply \(resource) (server-side apply)."
        case .helmRollback(_, _, let revision): "Roll \(resource) back to \(revision.map { "revision \($0)" } ?? "the previous revision")."
        case .gitopsSync(let controller, _, _, _): "Ask \(controller) to sync \(resource)."
        }
    }

    /// Details for the sheet, redacted: the patch body or the manifest is shown, never a Secret value.
    public var facts: [(label: String, value: String)] {
        var out: [(String, String)] = []
        if let namespace { out.append(("Namespace", namespace)) }
        switch self {
        case .patch(_, _, _, let type, let body):
            out.append(("Patch type", type))
            out.append(("Patch", Self.preview(body)))
        case .applyManifest(let document, _, _, _):
            out.append(("Manifest", Self.preview(document)))
        default: break
        }
        return out
    }

    static func preview(_ value: JSONValue, limit: Int = 1_200) -> String {
        let text = Redactor().redact(value.jsonString())
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}

public enum BeaconChangeOutcome: Sendable, Equatable {
    case applied(JSONValue)
    case declined
    case timedOut
    case failed(String)
    /// Policy, scope or lock refused it at execution time.
    case refused(String)
}

/// The app side of change requests: shows the confirmation sheet (`origin: .beacon`), runs the dry-run and then the real call
/// through the normal mutation path.
public protocol BeaconChangeHandling: Sendable {
    func supports(_ tool: ChangeTool) -> Bool
    /// Blocks until the person decides. It must return promptly (withdrawing the sheet) when its task is cancelled before the
    /// person approves; once approved and running it finishes the write and ignores cancellation, because a half-cancelled write
    /// leaves the cluster in an unknown state. `recheck` is called by the app immediately before it mutates: it returns the
    /// reason to refuse (the cluster became Production or read-only, the scope was revoked, Beacon was stopped, the app locked).
    func perform(_ request: BeaconChangeRequest, cluster: ClusterConfig, client: BeaconClientRef,
                 recheck: @escaping @Sendable () async -> String?) async -> BeaconChangeOutcome
}

/// Validates the arguments of a change-request tool. Pure.
public enum BeaconChangeParser {
    public struct Invalid: Error, Equatable { public let message: String }
    public static let maxBodyBytes = 256 * 1024

    public static func parse(_ tool: ChangeTool, _ input: JSONValue, discovery: DiscoveryInfo?) throws -> BeaconChangeRequest {
        switch tool {
        case .scale:
            let (kind, name, ns) = try target(input, discovery: discovery)
            guard let replicas = input["replicas"]?.intValue, (0...10_000).contains(replicas) else { throw Invalid(message: "replicas must be an integer from 0 to 10000.") }
            guard kind.plural == "deployments" || kind.plural == "statefulsets" || kind.plural == "replicasets" else { throw Invalid(message: "Only deployments, statefulsets and replicasets can be scaled.") }
            return .scale(kind: kind, name: name, namespace: ns, replicas: replicas)
        case .restartRollout:
            let (kind, name, ns) = try target(input, discovery: discovery)
            guard ["deployments", "statefulsets", "daemonsets"].contains(kind.plural) else { throw Invalid(message: "Only deployments, statefulsets and daemonsets can be restarted.") }
            return .restartRollout(kind: kind, name: name, namespace: ns)
        case .delete:
            let (kind, name, ns) = try target(input, discovery: discovery)
            return .delete(kind: kind, name: name, namespace: ns)
        case .patch:
            let (kind, name, ns) = try target(input, discovery: discovery)
            guard let type = input["patch_type"]?.stringValue, ["json", "merge", "strategic"].contains(type) else { throw Invalid(message: "patch_type must be json, merge or strategic.") }
            guard let body = input["patch"] else { throw Invalid(message: "patch is required.") }
            switch (type, body) {
            case ("json", .array(let ops)):
                guard !ops.isEmpty, ops.allSatisfy({ $0["op"]?.stringValue != nil && $0["path"]?.stringValue != nil }) else { throw Invalid(message: "Each JSON patch operation needs op and path.") }
            case ("json", _): throw Invalid(message: "A json patch is an array of operations.")
            case (_, .object(let fields)) where !fields.isEmpty: break
            default: throw Invalid(message: "A \(type) patch is a non-empty object.")
            }
            guard body.jsonString().utf8.count <= maxBodyBytes else { throw Invalid(message: "The patch is too large.") }
            return .patch(kind: kind, name: name, namespace: ns, patchType: type, body: body)
        case .applyManifest:
            guard let yaml = input["yaml"]?.stringValue, !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Invalid(message: "yaml is required.") }
            guard yaml.utf8.count <= maxBodyBytes else { throw Invalid(message: "The manifest is too large.") }
            let documents = YAMLCodec.parseDocuments(yaml)
            guard documents.count == 1, let document = documents.first else { throw Invalid(message: "Send exactly one YAML document per request.") }
            if let diagnostic = document.diagnostic { throw Invalid(message: "Line \(diagnostic.line): \(diagnostic.message)") }
            guard let value = document.value, case .object = value, let apiVersion = value["apiVersion"]?.stringValue,
                  let kindName = value["kind"]?.stringValue, let name = document.name, KubeNames.isObjectName(name) else {
                throw Invalid(message: "The document needs apiVersion, kind and metadata.name.")
            }
            let kind = KindResolver.resolve(apiVersion: apiVersion, kind: kindName, discovery: discovery)
            guard let kind else { throw Invalid(message: "Unknown kind \(kindName).") }
            // The namespace in the manifest is the one applied and the one the sheet shows; the argument, if given, must agree.
            let manifestNamespace = document.namespace
            if let manifestNamespace, !KubeNames.isDNSLabel(manifestNamespace) { throw Invalid(message: "The manifest namespace is not valid.") }
            if kind.namespaced {
                guard let manifestNamespace else { throw Invalid(message: "The manifest must set metadata.namespace.") }
                if let given = input["namespace"]?.stringValue, given != manifestNamespace { throw Invalid(message: "namespace does not match metadata.namespace.") }
            }
            return .applyManifest(document: value, kind: kind, name: name, namespace: kind.namespaced ? manifestNamespace : nil)
        case .helmRollback:
            let release = try objectName(input, "release")
            guard let ns = input["namespace"]?.stringValue, KubeNames.isDNSLabel(ns) else { throw Invalid(message: "namespace is required.") }
            var revision: Int?
            if let value = input["revision"] {
                guard let n = value.intValue, n > 0 else { throw Invalid(message: "revision must be a positive integer.") }
                revision = n
            }
            return .helmRollback(release: release, namespace: ns, revision: revision)
        case .gitopsSync:
            guard let controller = input["controller"]?.stringValue, ["flux", "argocd"].contains(controller) else { throw Invalid(message: "controller must be flux or argocd.") }
            guard let kind = input["kind"]?.stringValue, !kind.isEmpty, kind.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw Invalid(message: "kind must be a Kubernetes kind.") }
            guard let ns = input["namespace"]?.stringValue, KubeNames.isDNSLabel(ns) else { throw Invalid(message: "namespace is required.") }
            return .gitopsSync(controller: controller, kind: kind, name: try objectName(input, "name"), namespace: ns)
        }
    }

    private static func objectName(_ input: JSONValue, _ key: String) throws -> String {
        guard let value = input[key]?.stringValue, KubeNames.isObjectName(value) else { throw Invalid(message: "\(key) must be a valid Kubernetes name.") }
        return value
    }

    private static func target(_ input: JSONValue, discovery: DiscoveryInfo?) throws -> (ResourceKind, String, String?) {
        guard let text = input["kind"]?.stringValue, !text.isEmpty else { throw Invalid(message: "kind is required.") }
        guard let kind = KindResolver.resolve(text, discovery: discovery) else { throw Invalid(message: "Unknown kind \"\(text)\".") }
        let name = try objectName(input, "name")
        var ns: String?
        if kind.namespaced {
            guard let value = input["namespace"]?.stringValue, KubeNames.isDNSLabel(value) else { throw Invalid(message: "namespace is required.") }
            ns = value
        }
        return (kind, name, ns)
    }
}

/// Allows one pending change request per client (ARCHITECTURE-MAC section 9.2). The key is the client record (every session of one
/// client shares it); session-only clients have a key per session.
public final class BeaconPendingRequests: Sendable {
    private let pending = Mutex<Set<String>>([])
    public init() {}
    /// True when the slot was free (now taken).
    public func begin(_ client: String) -> Bool { pending.withLock { $0.insert(client).inserted } }
    public func end(_ client: String) { pending.withLock { _ = $0.remove(client) } }
    public func isPending(_ client: String) -> Bool { pending.withLock { $0.contains(client) } }
}
