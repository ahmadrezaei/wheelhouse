import Foundation
import WheelhouseKit

/// What "Review…" shows before the confirmation sheet: the change as a diff of the live object against the server's dry-run result
/// (ARCHITECTURE-MAC section 9.2: the proposed change is reviewed as an editor diff first).
///
/// The only request that can leave this type besides reads is a patch with `dryRun: true` hard-coded, the same dry-run the editor and the
/// confirmation sheet already make; the server stores nothing. It is made only from the review presenter, after the person pressed
/// Review… (First Mate's session cannot reach this type). A cluster that refuses dry-runs (read-only) gets a note instead of a diff.
/// Secrets are shown as key names and sizes only, and the diff never goes back to the model.
public struct ProposalPreview: Sendable, Equatable {
    public struct Entry: Identifiable, Sendable, Equatable {
        public var id: Int
        public var title: String
        public var isNew: Bool
        public var diff: [DiffLine]
        public var problem: String?
    }

    public var entries: [Entry]
    public var notes: [String]

    public init(entries: [Entry], notes: [String]) {
        self.entries = entries
        self.notes = notes
    }

    /// Builds the preview for a proposal that changes cluster objects. Commands, Helm upgrades and GitOps actions have nothing to diff.
    public static func load(for change: ProposedChange, cluster: ClusterConfig, client: any KubeClientProtocol) async -> ProposalPreview {
        guard case .refuse = MutationPolicy.decide(.mutation(dryRun: true), cluster: cluster, origin: change.origin) else {
            return await build(change, cluster: cluster, client: client)
        }
        return ProposalPreview(entries: [], notes: ["This cluster is read-only, so the server cannot be asked to preview the change."])
    }

    private static func build(_ change: ProposedChange, cluster: ClusterConfig, client: any KubeClientProtocol) async -> ProposalPreview {
        switch change.payload {
        case .patch(let kind, let name, let namespace, let patchType, let body):
            guard let patch = ProposalConfirmation.makePatch(type: patchType, body: body) else {
                return ProposalPreview(entries: [], notes: ["The patch could not be read."])
            }
            let entry = await entry(1, title: "\(kind.kind) \(namespace.map { "\($0)/" } ?? "")\(name)", kind: kind, name: name, namespace: namespace, patch: patch, client: client)
            return ProposalPreview(entries: [entry], notes: [])
        case .manifest(_, let documents):
            var entries: [Entry] = []
            var discovery: DiscoveryInfo?
            for (index, document) in documents.enumerated() {
                let kindName = document["kind"]?.stringValue ?? "?"
                let name = document.value(at: "metadata.name")?.stringValue ?? "?"
                let apiVersion = document["apiVersion"]?.stringValue ?? ""
                var kind = KindResolver.resolve(apiVersion: apiVersion, kind: kindName)
                if kind == nil {
                    if discovery == nil { discovery = try? await client.discovery() }
                    kind = KindResolver.resolve(apiVersion: apiVersion, kind: kindName, discovery: discovery)
                }
                guard let kind else {
                    entries.append(Entry(id: index + 1, title: "\(kindName) \(name)", isNew: false, diff: [], problem: "Unknown kind \(kindName)."))
                    continue
                }
                let namespace = kind.namespaced ? (document.value(at: "metadata.namespace")?.stringValue ?? cluster.defaultNamespace ?? "default") : nil
                entries.append(await entry(index + 1, title: "\(kindName) \(namespace.map { "\($0)/" } ?? "")\(name)", kind: kind, name: name, namespace: namespace,
                                           patch: .apply(document), client: client))
            }
            return ProposalPreview(entries: entries, notes: [])
        case .command: return ProposalPreview(entries: [], notes: ["A command is inserted into your terminal, not applied. You press Return."])
        case .helmUpgrade: return ProposalPreview(entries: [], notes: ["A Helm upgrade is reviewed in Chart Room."])
        case .gitopsAction: return ProposalPreview(entries: [], notes: ["A GitOps action is reviewed in Tides."])
        }
    }

    private static func entry(_ id: Int, title: String, kind: ResourceKind, name: String, namespace: String?, patch: KubePatch, client: any KubeClientProtocol) async -> Entry {
        let redactor = Redactor()
        var before = ""
        var isNew = false
        do {
            before = text(try await client.getRaw(kind, name: name, namespace: namespace), kind: kind, redactor: redactor)
        } catch KubeError.notFound {
            isNew = true
        } catch {
            return Entry(id: id, title: title, isNew: false, diff: [], problem: (error as? KubeError)?.summary ?? error.localizedDescription)
        }
        do {
            // Always a dry run: the server validates and returns the object it would store, and stores nothing.
            let result = try await client.patch(kind, name: name, namespace: namespace, patch: patch, options: MutationOptions(dryRun: true))
            let after = text(result, kind: kind, redactor: redactor)
            return Entry(id: id, title: title, isNew: isNew, diff: LineDiff.diff(old: before, new: after), problem: nil)
        } catch {
            return Entry(id: id, title: title, isNew: isNew, diff: [], problem: (error as? KubeError)?.summary ?? error.localizedDescription)
        }
    }

    /// YAML of the object as the person sees it: Secrets reduced to key names and sizes, managed fields and per-write noise removed.
    static func text(_ raw: JSONValue, kind: ResourceKind, redactor: Redactor) -> String {
        var object = redactor.resource(raw, kind: kind)
        for path in ["metadata.resourceVersion", "metadata.generation", "metadata.managedFields", "status"] { object.setValue(nil, at: path) }
        return YAMLCodec.dump(object)
    }
}
