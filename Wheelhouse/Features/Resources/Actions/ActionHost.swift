import SwiftUI
import Observation
import WheelhouseKit
import WheelhouseUI

/// One object an action applies to.
struct ResourceTarget: Identifiable, Hashable {
    let kind: ResourceKind
    let object: Unstructured
    var id: String { "\(kind.id)/\(namespace ?? "-")/\(name)" }
    var name: String { object.metadata.name }
    var namespace: String? { object.metadata.namespace }
    var resource: String { "\(kind.kind.lowercased())/\(name)" }
    var replicas: Int? { object.int("spec.replicas") }
    var isCordoned: Bool { object.bool("spec.unschedulable") ?? false }
    var isSuspended: Bool { object.bool("spec.suspend") ?? false }
    var isPaused: Bool { object.bool("spec.paused") ?? false }
    var ref: (ClusterID) -> ResourceRef { { ResourceRef(clusterID: $0, kind: kind, namespace: namespace, name: name) } }
}

enum ActionSheet: Identifiable {
    case scale(ResourceTarget)
    case rollback(ResourceTarget)
    case deleteOptions(ResourceTarget)
    case drain(ResourceTarget)
    var id: String {
        switch self {
        case .scale(let t): "scale-\(t.id)"
        case .rollback(let t): "rollback-\(t.id)"
        case .deleteOptions(let t): "delete-\(t.id)"
        case .drain(let t): "drain-\(t.id)"
        }
    }
}

struct ActionToast: Identifiable {
    let id = UUID()
    var message: String
    var symbol = "checkmark.circle.fill"
    var tone: StatusTone = .healthy
    var undoTitle: String?
    var undo: (@MainActor @Sendable () async -> Void)?
}

typealias DryRunBlock = @MainActor @Sendable () async -> DryRunOutcome

/// Builds every confirmation request for resource actions and owns the sheet/confirm/toast presentation state.
/// Attach with `.actionHost(host)`. Mutations always go through `ConfirmRequest` (dry-run first, typed confirmation on production).
@MainActor @Observable
final class ActionHost {
    let session: ClusterSession
    var sheet: ActionSheet?
    var confirm: ConfirmRequest?
    var toast: ActionToast?
    @ObservationIgnored private weak var registry: ClusterRegistry?
    @ObservationIgnored private var queued: ConfirmRequest?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(session: ClusterSession) { self.session = session }

    /// Called by `.actionHost(_:)`. From then on the host resolves the cluster's CURRENT config and client through the registry,
    /// so editing a cluster (read-only / production) while a screen is open takes effect immediately.
    func bind(_ registry: ClusterRegistry) { self.registry = registry }

    /// The cluster as configured now (falls back to the config captured at creation before `bind`).
    var cluster: ClusterConfig { registry?.config(for: session.id) ?? session.config }
    /// False once the registry no longer knows the cluster.
    private var exists: Bool { registry == nil || registry?.config(for: session.id) != nil }
    /// Mutating UI is hidden (not disabled) on read-only clusters.
    var canMutate: Bool { exists && !cluster.readOnly }
    /// The live client (a replaced session after a settings change, never the stale one).
    var client: any KubeClientProtocol { registry?.session(for: session.id)?.client ?? session.client }

    // MARK: Presentation

    func queue(_ request: ConfirmRequest) {
        if sheet != nil { queued = request; sheet = nil } else { confirm = request }
    }

    func flushQueued() {
        if let q = queued { queued = nil; confirm = q }
    }

    func show(_ toast: ActionToast) {
        self.toast = toast
        toastTask?.cancel()
        let id = toast.id
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(toast.undo == nil ? 4 : 6))
            if !Task.isCancelled, self?.toast?.id == id { self?.toast = nil }
        }
    }

    func dismissToast() { toast = nil }

    private func failed(_ error: Error, _ what: String) {
        show(ActionToast(message: "\(what) failed: \((error as? KubeError)?.summary ?? error.localizedDescription)", symbol: "xmark.octagon.fill", tone: .critical))
    }

    static func dry(_ ok: String, _ op: @escaping @Sendable () async throws -> Void) -> DryRunBlock {
        {
            do { try await op(); return .passed(ok) }
            catch { return .failed((error as? KubeError)?.summary ?? error.localizedDescription) }
        }
    }

    // MARK: Entry points used by lists and details

    func scale(_ t: ResourceTarget) { sheet = .scale(t) }
    func rollback(_ t: ResourceTarget) { sheet = .rollback(t) }
    func drain(_ t: ResourceTarget) { sheet = .drain(t) }
    func delete(_ t: ResourceTarget) {
        switch t.kind.kind {
        case "Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job", "CronJob": sheet = .deleteOptions(t)
        default: confirm = deleteRequest(t, propagation: .background)
        }
    }
    func restart(_ t: ResourceTarget) { confirm = restartRequest(t) }
    func cordon(_ t: ResourceTarget) { confirm = cordonRequest(t, cordon: !t.isCordoned) }
    func suspend(_ t: ResourceTarget) { confirm = suspendRequest(t, suspend: !t.isSuspended) }
    func trigger(_ t: ResourceTarget) { confirm = triggerRequest(t) }
    func pauseRollout(_ t: ResourceTarget) { confirm = pauseRequest(t, pause: !t.isPaused) }

    // MARK: Requests

    /// `from` overrides the replica count shown as "current" (Undo knows what it just set).
    func scaleRequest(_ t: ResourceTarget, to replicas: Int, from known: Int? = nil) -> ConfirmRequest {
        let c = client, kind = t.kind, name = t.name, ns = t.namespace
        let previous = known ?? t.replicas
        let current = previous ?? 0
        return ConfirmRequest(
            title: "Scale \(name)?", message: "Change the desired replica count of \(t.resource) from \(current) to \(replicas).", verb: "Scale",
            cluster: cluster, namespace: ns, resource: t.resource, confirmationText: name,
            facts: [.init("Replicas", "\(previous.map(String.init) ?? "?") → \(replicas)")],
            isDisruptive: ScalePolicy.isDisruptive(from: current, to: replicas),
            dryRun: Self.dry("Server accepted \(replicas) replica\(replicas == 1 ? "" : "s")") { _ = try await c.scale(kind, name: name, namespace: ns, replicas: replicas, options: MutationOptions(dryRun: true)) },
            action: { [weak self] in
                _ = try await c.scale(kind, name: name, namespace: ns, replicas: replicas)
                // Undo re-enters the confirm flow (dry-run, typed confirmation on production). No Undo when the old count is unknown.
                if let previous {
                    self?.show(ActionToast(message: "Scaled \(name) to \(replicas)", undoTitle: "Undo", undo: { [weak self] in
                        guard let self else { return }
                        self.queue(self.scaleRequest(t, to: previous, from: replicas))
                    }))
                } else {
                    self?.show(ActionToast(message: "Scaled \(name) to \(replicas)"))
                }
            })
    }

    func restartRequest(_ t: ResourceTarget) -> ConfirmRequest {
        let c = client, kind = t.kind, name = t.name, ns = t.namespace
        return ConfirmRequest(
            title: "Restart \(name)?", message: "Triggers a rolling restart: pods are replaced one by one with the same template.", verb: "Restart Rollout",
            cluster: cluster, namespace: ns, resource: t.resource, confirmationText: name,
            facts: t.replicas.map { [.init("Pods affected", "\($0)")] } ?? [],
            dryRun: Self.dry("Server accepted the restart") { _ = try await c.restartRollout(kind, name: name, namespace: ns, options: MutationOptions(dryRun: true)) },
            action: { [weak self] in
                _ = try await c.restartRollout(kind, name: name, namespace: ns)
                self?.show(ActionToast(message: "Restarting \(name)", symbol: "arrow.triangle.2.circlepath"))
            })
    }

    func deleteRequest(_ t: ResourceTarget, propagation: PropagationPolicy?) -> ConfirmRequest {
        let c = client, kind = t.kind, name = t.name, ns = t.namespace
        var facts: [ConfirmRequest.Fact] = []
        if let p = propagation, ["Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job", "CronJob"].contains(kind.kind) { facts.append(.init("Dependents", p.title)) }
        if kind == .namespace { facts.append(.init("Includes", "every resource in the namespace")) }
        return ConfirmRequest(
            title: "Delete \(name)?", message: "Permanently deletes \(t.resource). This cannot be undone.", verb: "Delete \(kind.kind)", isDestructive: true,
            cluster: cluster, namespace: ns, resource: t.resource, confirmationText: name, facts: facts, alwaysRequireTyping: kind == .namespace,
            dryRun: Self.dry("Server accepted the deletion") { try await c.delete(kind, name: name, namespace: ns, options: DeleteOptions(propagation: propagation, dryRun: true)) },
            action: { [weak self] in
                try await c.delete(kind, name: name, namespace: ns, options: DeleteOptions(propagation: propagation))
                self?.show(ActionToast(message: "Deleted \(t.resource)", symbol: "trash.fill", tone: .info))
            })
    }

    func cordonRequest(_ t: ResourceTarget, cordon: Bool) -> ConfirmRequest {
        let c = client, name = t.name
        return ConfirmRequest(
            title: "\(cordon ? "Cordon" : "Uncordon") \(name)?",
            message: cordon ? "Marks the node unschedulable. Running pods are not affected, but no new pods will be placed on it." : "Marks the node schedulable again so new pods can be placed on it.",
            verb: cordon ? "Cordon" : "Uncordon", cluster: cluster, resource: t.resource, confirmationText: name, isDisruptive: cordon,
            dryRun: Self.dry("Server accepted the change") { _ = try await c.setNodeUnschedulable(name: name, unschedulable: cordon, options: MutationOptions(dryRun: true)) },
            action: { [weak self] in
                _ = try await c.setNodeUnschedulable(name: name, unschedulable: cordon)
                self?.show(ActionToast(message: cordon ? "\(name) cordoned" : "\(name) uncordoned", undoTitle: "Undo", undo: { [weak self] in
                    guard let self else { return }
                    self.queue(self.cordonRequest(t, cordon: !cordon))
                }))
            })
    }

    func suspendRequest(_ t: ResourceTarget, suspend: Bool) -> ConfirmRequest {
        let c = client, name = t.name, ns = t.namespace ?? "default"
        return ConfirmRequest(
            title: "\(suspend ? "Suspend" : "Resume") \(name)?",
            message: suspend ? "No new Jobs will be created until the CronJob is resumed. Running Jobs continue." : "The CronJob will create Jobs on its schedule again.",
            verb: suspend ? "Suspend" : "Resume", cluster: cluster, namespace: ns, resource: t.resource, confirmationText: name, isDisruptive: suspend,
            dryRun: Self.dry("Server accepted the change") { _ = try await c.setCronJobSuspended(name: name, namespace: ns, suspended: suspend, options: MutationOptions(dryRun: true)) },
            action: { [weak self] in
                _ = try await c.setCronJobSuspended(name: name, namespace: ns, suspended: suspend)
                self?.show(ActionToast(message: suspend ? "\(name) suspended" : "\(name) resumed", undoTitle: "Undo", undo: { [weak self] in
                    guard let self else { return }
                    self.queue(self.suspendRequest(t, suspend: !suspend))
                }))
            })
    }

    func triggerRequest(_ t: ResourceTarget) -> ConfirmRequest {
        let c = client, name = t.name, ns = t.namespace ?? "default"
        let jobBody = CronJobTrigger.makeJob(cronJob: t.object)
        let jobName = jobBody?.value(at: "metadata.name")?.stringValue ?? "\(name)-manual"
        return ConfirmRequest(
            title: "Trigger \(name) now?", message: "Creates a Job from the CronJob’s template immediately, outside its schedule.", verb: "Create Job",
            cluster: cluster, namespace: ns, resource: t.resource, confirmationText: name, facts: [.init("New Job", jobName)], isDisruptive: false,
            dryRun: Self.dry("Server accepted the Job") {
                guard let body = jobBody else { throw KubeError.invalid(message: "CronJob has no jobTemplate", causes: []) }
                _ = try await c.create(.job, namespace: ns, body: body, options: MutationOptions(dryRun: true))
            },
            action: { [weak self] in
                guard let body = jobBody else { throw KubeError.invalid(message: "CronJob has no jobTemplate", causes: []) }
                _ = try await c.create(.job, namespace: ns, body: body)
                self?.show(ActionToast(message: "Created Job \(jobName)", symbol: "play.circle.fill"))
            })
    }

    func pauseRequest(_ t: ResourceTarget, pause: Bool) -> ConfirmRequest {
        let c = client, name = t.name, ns = t.namespace
        let patch = KubePatch.merge(["spec": ["paused": pause ? true : .null]])
        return ConfirmRequest(
            title: "\(pause ? "Pause" : "Resume") rollout of \(name)?",
            message: pause ? "Template changes will not roll out until the rollout is resumed." : "Pending template changes will roll out.",
            verb: pause ? "Pause Rollout" : "Resume Rollout", cluster: cluster, namespace: ns, resource: t.resource, confirmationText: name, isDisruptive: pause,
            dryRun: Self.dry("Server accepted the change") { _ = try await c.patch(.deployment, name: name, namespace: ns, patch: patch, options: MutationOptions(dryRun: true)) },
            action: { [weak self] in
                _ = try await c.patch(.deployment, name: name, namespace: ns, patch: patch)
                self?.show(ActionToast(message: pause ? "Rollout paused" : "Rollout resumed", symbol: pause ? "pause.circle.fill" : "play.circle.fill"))
            })
    }

    func rollbackRequest(_ t: ResourceTarget, to revision: RolloutRevision, from current: RolloutRevision?) -> ConfirmRequest? {
        // Like `kubectl rollout undo`: refuse paused rollouts, and no-op rollbacks to the template already running.
        guard RolloutHistory.rollbackBlocker(deployment: t.object) == nil,
              !RolloutHistory.matchesCurrentTemplate(revision, deployment: t.object),
              let patch = RolloutHistory.rollbackPatch(to: revision, deploymentAnnotations: t.object.metadata.annotations) else { return nil }
        let c = client, name = t.name, ns = t.namespace
        var facts: [ConfirmRequest.Fact] = [.init("Revision", "\(current.map { "\($0.revision)" } ?? "?") → \(revision.revision)")]
        if !revision.images.isEmpty { facts.append(.init("Images", revision.images.map { $0.split(separator: "/").last.map(String.init) ?? $0 }.joined(separator: ", "))) }
        return ConfirmRequest(
            title: "Roll back \(name)?", message: "Restores the pod template of revision \(revision.revision) (\(revision.replicaSetName)) and rolls it out.", verb: "Roll Back",
            cluster: cluster, namespace: ns, resource: t.resource, confirmationText: name, facts: facts,
            dryRun: Self.dry("Server accepted the rollback") { _ = try await c.patch(.deployment, name: name, namespace: ns, patch: patch, options: MutationOptions(dryRun: true)) },
            action: { [weak self] in
                _ = try await c.patch(.deployment, name: name, namespace: ns, patch: patch)
                self?.show(ActionToast(message: "Rolling back \(name) to revision \(revision.revision)", symbol: "arrow.uturn.backward.circle.fill"))
            })
    }
}

extension PropagationPolicy {
    var title: String {
        switch self { case .background: "Background"; case .foreground: "Foreground"; case .orphan: "Orphan" }
    }
    var explanation: String {
        switch self {
        case .background: "Deletes the object now; the garbage collector removes dependents (pods, ReplicaSets) afterwards."
        case .foreground: "Waits until dependents are deleted before the object itself disappears."
        case .orphan: "Deletes only this object and leaves its dependents running."
        }
    }
}

// MARK: - Presentation modifier

struct ActionHostModifier: ViewModifier {
    @Bindable var host: ActionHost
    @Environment(ClusterRegistry.self) private var registry

    func body(content: Content) -> some View {
        content
            .sheet(item: $host.sheet, onDismiss: { host.flushQueued() }) { sheet in
                switch sheet {
                case .scale(let t): ScaleSheet(host: host, target: t)
                case .rollback(let t): RollbackSheet(host: host, target: t)
                case .deleteOptions(let t): DeleteOptionsSheet(host: host, target: t)
                case .drain(let t): DrainSheet(host: host, target: t)
                }
            }
            .confirmSheet($host.confirm)
            .onAppear { host.bind(registry) }
            .overlay(alignment: .bottom) {
                if let toast = host.toast {
                    ToastBanner(toast: toast, onUndo: {
                        host.dismissToast()
                        if let undo = toast.undo { Task { await undo() } }
                    }, onDismiss: { host.dismissToast() })
                    .padding(.horizontal, Spacing.l).padding(.bottom, Spacing.m)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: host.toast?.id)
    }
}

extension View {
    func actionHost(_ host: ActionHost) -> some View { modifier(ActionHostModifier(host: host)) }
}

struct ToastBanner: View {
    let toast: ActionToast
    var onUndo: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol).foregroundStyle(toast.tone.color)
            Text(toast.message).font(.subheadline).lineLimit(3)
            Spacer(minLength: 4)
            if let title = toast.undoTitle, toast.undo != nil {
                Button(title, action: onUndo).font(.subheadline.weight(.semibold)).buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: 560)
        .glassEffect(.regular, in: Capsule())
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}
