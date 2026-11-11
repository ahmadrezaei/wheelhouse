import Foundation
import LocalAuthentication
import Synchronization
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI

/// Touch ID or the account password (`deviceOwnerAuthentication`). Automated tests inject their own; none ever calls this.
struct LocalAuthenticator: BeaconAuthenticating {
    func authenticate(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { throw BeaconAuthenticationFailed() }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else { throw BeaconAuthenticationFailed() }
        } catch { throw BeaconAuthenticationFailed() }
    }
}

/// The normal mutation path for Beacon change requests (ARCHITECTURE-MAC section 10.2).
///
/// Each request becomes a `ConfirmRequest(origin: .beacon(client:))`. The sheet has no default button, ignores input for one second,
/// runs the server dry-run first, and (like every non-UI origin) can never skip typing the name on Production, which the policy
/// refuses outright. Its `action` is the only thing here that mutates: it re-checks policy, scope, lock and Beacon state first and
/// then runs the same call the dry-run validated.
@MainActor
final class MacBeaconChanges: BeaconChangeHandling {
    private let registry: ClusterRegistry
    private let presenter: BeaconPresenter

    init(registry: ClusterRegistry, presenter: BeaconPresenter) {
        self.registry = registry
        self.presenter = presenter
    }

    /// Helm rollback and GitOps sync have no executor yet (they arrive with their own milestones), so they are not offered.
    nonisolated func supports(_ tool: ChangeTool) -> Bool {
        switch tool {
        case .applyManifest, .patch, .scale, .restartRollout, .delete: true
        case .helmRollback, .gitopsSync: false
        }
    }

    nonisolated func perform(_ request: BeaconChangeRequest, cluster: ClusterConfig, client: BeaconClientRef,
                             recheck: @escaping @Sendable () async -> String?) async -> BeaconChangeOutcome {
        return await run(request, cluster: cluster, client: client, recheck: recheck)
    }

    private final class Result: @unchecked Sendable {
        var outcome: BeaconChangeOutcome?
        var lastFailure: String?
        /// Set once the write started: from then on a cancel no longer withdraws the sheet.
        var executing = false
    }

    private func run(_ request: BeaconChangeRequest, cluster: ClusterConfig, client: BeaconClientRef,
                     recheck: @escaping @Sendable () async -> String?) async -> BeaconChangeOutcome {
        guard let session = registry.session(for: cluster.id) else { return .refused("The cluster is not connected.") }
        let kube = session.client
        let result = Result()
        let sheet = Self.confirmRequest(for: request, cluster: cluster, client: client, kube: kube, recheck: recheck, result: result)
        // Cancellation (client cancelled, timeout, Beacon stopped, lock) withdraws the sheet; once the write started it finishes.
        await presenter.confirm(sheet)
        // A write that already started is not abandoned: wait (briefly) for its result.
        var waited = 0
        while result.executing, result.outcome == nil, result.lastFailure == nil, waited < 6_000 {
            try? await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        if let outcome = result.outcome { return outcome }
        if let failure = result.lastFailure { return .failed(failure) }
        return .declined
    }

    static func confirmRequest(for request: BeaconChangeRequest, cluster: ClusterConfig, client: BeaconClientRef, kube: any KubeClientProtocol,
                               recheck: @escaping @Sendable () async -> String?, result: AnyObject?) -> ConfirmRequest {
        let box = result as? Result ?? Result()
        var facts = request.facts.map { ConfirmRequest.Fact($0.label, $0.value) }
        // The sheet shows what the APP knows. The client's own name is a label, and it is shown as one.
        facts.append(ConfirmRequest.Fact("Client (as it calls itself)", client.label))
        if case .applyManifest(_, let kind, _, _) = request, kind.group == "rbac.authorization.k8s.io" || !kind.namespaced {
            facts.append(ConfirmRequest.Fact("Warning", kind.namespaced ? "This changes access control." : "This object is cluster-scoped."))
        }
        let origin = ChangeOrigin.beacon(client: client.id)
        return ConfirmRequest(
            title: "\(request.verb) \(request.resource)?",
            message: "\(client.label) asks to: \(request.summary)",
            verb: request.verb, isDestructive: request.isDestructive, cluster: cluster, namespace: request.namespace, resource: request.resource,
            confirmationText: request.confirmationText, facts: facts, origin: origin,
            dryRun: {
                do {
                    _ = try await Self.execute(request, on: kube, dryRun: true)
                    return .passed("The server accepted the change in a dry run.")
                } catch { return .failed((error as? KubeError)?.summary ?? error.localizedDescription) }
            },
            action: {
                // Executing from here on: a cancel no longer abandons the call, even while the re-check runs.
                box.executing = true
                if let reason = await recheck() { box.executing = false; box.outcome = .refused(reason); throw BeaconRefused(reason: reason) }
                do {
                    let output = try await Self.execute(request, on: kube, dryRun: false)
                    box.outcome = .applied(output)
                } catch {
                    box.executing = false
                    box.lastFailure = (error as? KubeError)?.summary ?? error.localizedDescription
                    throw error
                }
            })
    }

    struct BeaconRefused: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// The same call for the dry-run and the real run.
    static func execute(_ request: BeaconChangeRequest, on kube: any KubeClientProtocol, dryRun: Bool) async throws -> JSONValue {
        let options = MutationOptions(dryRun: dryRun)
        switch request {
        case .scale(let kind, let name, let namespace, let replicas):
            return try await kube.scale(kind, name: name, namespace: namespace, replicas: replicas, options: options)
        case .restartRollout(let kind, let name, let namespace):
            return try await kube.restartRollout(kind, name: name, namespace: namespace, options: options)
        case .delete(let kind, let name, let namespace):
            try await kube.delete(kind, name: name, namespace: namespace, options: DeleteOptions(dryRun: dryRun))
            return ["deleted": .string("\(kind.kind.lowercased())/\(name)")]
        case .patch(let kind, let name, let namespace, let type, let body):
            let patch: KubePatch
            switch (type, body) {
            case ("json", .array(let ops)): patch = .json(ops)
            case ("merge", .object): patch = .merge(body)
            case ("strategic", .object): patch = .strategicMerge(body)
            default: throw KubeError.unsupported("Bad patch.")
            }
            _ = try await kube.patch(kind, name: name, namespace: namespace, patch: patch, options: options)
            return ["patched": .string("\(kind.kind.lowercased())/\(name)")]
        case .applyManifest(let document, let kind, let name, let namespace):
            _ = try await kube.patch(kind, name: name, namespace: namespace, patch: .apply(document), options: options)
            return ["applied": .string("\(kind.kind.lowercased())/\(name)")]
        case .helmRollback, .gitopsSync:
            throw KubeError.unsupported("This change type is not available yet.")
        }
    }
}
