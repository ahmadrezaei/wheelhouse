import Foundation
import WheelhouseKit
import WheelhouseUI

/// Turns a ``GitOpsActionPlan`` into the ConfirmSheet request (ARCHITECTURE-MAC §7). Every Tides action:
/// - goes through the sheet with `origin: .tides`,
/// - runs a server dry-run of the same patch first (the primary button stays disabled until it passes),
/// - on Production requires typing the app name,
/// - for Sync with Prune lists the resources it will delete and uses the destructive style.
enum TidesConfirmations {
    /// At most this many resources are listed one by one in the sheet; the rest are counted.
    static let listLimit = 30

    @MainActor
    static func request(plan: GitOpsActionPlan, cluster: ClusterConfig, client: any KubeClientProtocol, detection: GitOpsDetection,
                        log: any ActivityLogging = NoopActivityLog(), onApplied: @escaping @MainActor @Sendable (GitOpsActionPlan) -> Void = { _ in }) -> ConfirmRequest {
        var facts = plan.facts.map { ConfirmRequest.Fact($0.label, $0.value) }
        let listed = plan.pruneList.prefix(listLimit)
        for r in listed { facts.append(ConfirmRequest.Fact("Delete", r.display)) }
        if plan.pruneList.count > listLimit { facts.append(ConfirmRequest.Fact("Delete", "and \(plan.pruneList.count - listLimit) more")) }
        let clusterID = cluster.id
        let object = "\(plan.app.kind.kind.lowercased())/\(plan.app.name)"
        let verb = plan.kind.rawValue
        return ConfirmRequest(
            title: plan.title,
            message: plan.message,
            verb: plan.verb,
            isDestructive: plan.isDestructive,
            cluster: cluster,
            namespace: plan.app.namespace,
            resource: "\(plan.app.kind.kind)/\(plan.app.name)",
            confirmationText: plan.app.name,
            facts: facts,
            origin: .tides,
            dryRun: {
                do {
                    try await plan.dryRun(client: client)
                    return .passed("The server accepted the patch.")
                } catch {
                    return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            },
            action: {
                do {
                    try await plan.execute(client: client, detection: detection)
                    log.record(ActivityEntry(cluster: clusterID, origin: .tides, verb: verb, object: object, result: "ok"))
                    onApplied(plan)
                } catch {
                    log.record(ActivityEntry(cluster: clusterID, origin: .tides, verb: verb, object: object, result: "failed: \(error.localizedDescription)"))
                    throw error
                }
            })
    }
}
