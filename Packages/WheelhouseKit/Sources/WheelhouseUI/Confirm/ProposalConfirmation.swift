import Foundation
import WheelhouseKit

/// Builds the normal ``ConfirmRequest`` for a First Mate proposal (ARCHITECTURE-MAC section 9.2).
///
/// This is the only path from a ``ProposedChange`` to a cluster: the mutation lives inside the request's `action`, which runs
/// only when the person confirms in the sheet. The request carries `origin: .firstMate(conversation:)`, so ``MutationPolicy``
/// forces typed confirmation on Production, the sheet ignores input for one second and the origin badge is shown.
///
/// **Presenter contract (M11b).**
/// - Get the client from `registry.session(for: change.cluster)`; this builder refuses a cluster that is not the proposal's.
/// - Call `coordinator.beginReview(change.id)` before presenting, `coordinator.reviewDismissed(change.id)` from
///   `.sheet(onDismiss:)`, and `coordinator.markDeclined(change.id)` from a Decline button.
/// - Section 9.2 says "Review..." opens the normal editor first: M11b must show the proposed change as an editor diff and
///   present this request from that review step. The facts here are a summary for the sheet, not a substitute for the diff.
///
/// Commands (inserted into the terminal, M5b), Helm upgrades (M6b) and GitOps actions (M9) have their own review flows and
/// return nil here until those milestones provide them.
public enum ProposalConfirmation {
    @MainActor
    public static func request(for change: ProposedChange, cluster: ClusterConfig, client: any KubeClientProtocol,
                               coordinator: ProposalCoordinator? = nil) -> ConfirmRequest? {
        guard cluster.id == change.cluster else { return nil }
        switch change.payload {
        case .patch(let kind, let name, let namespace, let patchType, let body):
            guard let patch = makePatch(type: patchType, body: body) else { return nil }
            let facts: [ConfirmRequest.Fact] = [
                .init("Patch type", patchType),
                .init("Namespace", kind.namespaced ? (namespace ?? "(none)") : "(cluster-scoped)"),
                .init("Patch", preview(body)), .init("Proposal", change.id),
            ] + reasonFact(change)
            return ConfirmRequest(
                title: "Apply patch to \(kind.kind) \(name)",
                message: "First Mate proposes changing \(kind.kind.lowercased())/\(name) on \(cluster.name).",
                verb: "Apply Patch", cluster: cluster, namespace: namespace, resource: "\(kind.kind.lowercased())/\(name)",
                confirmationText: name, facts: facts, origin: change.origin,
                dryRun: { await dryRun { try await client.patch(kind, name: name, namespace: namespace, patch: patch, options: MutationOptions(dryRun: true)) } },
                action: {
                    do {
                        _ = try await client.patch(kind, name: name, namespace: namespace, patch: patch)
                        coordinator?.markApplied(change.id)
                    } catch {
                        // The sheet stays open and the person may retry; the proposal fails only if the sheet closes without success.
                        coordinator?.recordAttemptFailure(change.id, message: error.localizedDescription)
                        throw error
                    }
                })
        case .manifest(_, let documents):
            guard !documents.isEmpty else { return nil }
            let defaultNamespace = cluster.defaultNamespace ?? "default"
            let first = documents[0]
            let label = documents.count == 1 ? "\(first["kind"]?.stringValue ?? "object")/\(first.value(at: "metadata.name")?.stringValue ?? "")" : "\(documents.count) objects"
            var facts: [ConfirmRequest.Fact] = documents.enumerated().map { index, document in
                .init("Object \(index + 1)", describe(document, defaultNamespace: defaultNamespace))
            }
            facts.append(.init("Proposal", change.id))
            facts += reasonFact(change)
            return ConfirmRequest(
                title: "Apply \(label)", message: "First Mate proposes applying \(label) to \(cluster.name) (server-side apply).",
                verb: "Apply", cluster: cluster, resource: label,
                confirmationText: documents.count == 1 ? (first.value(at: "metadata.name")?.stringValue ?? label) : "\(documents.count)",
                facts: facts, origin: change.origin,
                dryRun: { await dryRun { try await apply(documents, client: client, defaultNamespace: defaultNamespace, dryRun: true) } },
                action: {
                    do {
                        try await apply(documents, client: client, defaultNamespace: defaultNamespace, dryRun: false)
                        coordinator?.markApplied(change.id)
                    } catch {
                        coordinator?.recordAttemptFailure(change.id, message: error.localizedDescription)
                        throw error
                    }
                })
        case .command, .helmUpgrade, .gitopsAction:
            return nil
        }
    }

    // MARK: Helpers

    static func makePatch(type: String, body: JSONValue) -> KubePatch? {
        switch (type, body) {
        case ("json", .array(let ops)): .json(ops)
        case ("merge", .object): .merge(body)
        case ("strategic", .object): .strategicMerge(body)
        case ("apply", .object): .apply(body)
        default: nil
        }
    }

    /// A short, redacted look at a patch for the sheet.
    static func preview(_ body: JSONValue, limit: Int = 600) -> String {
        let text = Redactor().redact(body.jsonString())
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// `Kind namespace/name`, with the namespace shown and never silently assumed.
    static func describe(_ document: JSONValue, defaultNamespace: String) -> String {
        let kindName = document["kind"]?.stringValue ?? "?"
        let name = document.value(at: "metadata.name")?.stringValue ?? "?"
        let apiVersion = document["apiVersion"]?.stringValue ?? ""
        let kind = KindResolver.resolve(apiVersion: apiVersion, kind: kindName)
        if let kind, !kind.namespaced { return "\(kindName) \(name) (cluster-scoped)" }
        if let namespace = document.value(at: "metadata.namespace")?.stringValue { return "\(kindName) \(namespace)/\(name)" }
        // A kind only discovery knows (a custom resource) may be cluster-scoped: do not claim a namespace for it.
        if kind == nil { return "\(kindName) \(name) (scope resolved at apply)" }
        return "\(kindName) \(defaultNamespace)/\(name) (namespace not set in the manifest)"
    }

    private static func reasonFact(_ change: ProposedChange) -> [ConfirmRequest.Fact] {
        change.reason.isEmpty ? [] : [.init("Reason", Redactor().redact(change.reason))]
    }

    private static func dryRun<T: Sendable>(_ work: @Sendable () async throws -> T) async -> DryRunOutcome {
        do { _ = try await work(); return .passed("The server accepted the change in a dry run.") }
        catch let error as KubeError { return .failed(error.summary) }
        catch { return .failed(error.localizedDescription) }
    }

    /// Server-side apply of each document, in order. Stops at the first failure.
    private static func apply(_ documents: [JSONValue], client: any KubeClientProtocol, defaultNamespace: String, dryRun: Bool) async throws {
        var discovery: DiscoveryInfo?
        for document in documents {
            guard let apiVersion = document["apiVersion"]?.stringValue, let kindName = document["kind"]?.stringValue,
                  let name = document.value(at: "metadata.name")?.stringValue else { throw KubeError.unsupported("A document has no kind or name.") }
            var kind = KindResolver.resolve(apiVersion: apiVersion, kind: kindName)
            if kind == nil {
                if discovery == nil { discovery = try await client.discovery() }
                kind = KindResolver.resolve(apiVersion: apiVersion, kind: kindName, discovery: discovery)
            }
            guard let kind else { throw KubeError.unsupported("Unknown kind \(kindName).") }
            // The sheet listed this namespace for the person; it is the same value used here.
            let namespace = kind.namespaced ? (document.value(at: "metadata.namespace")?.stringValue ?? defaultNamespace) : nil
            _ = try await client.patch(kind, name: name, namespace: namespace, patch: .apply(document), options: MutationOptions(dryRun: dryRun))
        }
    }
}
