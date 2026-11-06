import Foundation
import Observation

public struct DrainOptions: Hashable, Sendable {
    /// `--ignore-daemonsets`
    public var ignoreDaemonSets = true
    /// `--delete-emptydir-data`
    public var deleteEmptyDirData = false
    /// `--force`: also evict pods that have no controller.
    public var forceUnmanaged = false
    /// nil = each pod's own grace period.
    public var gracePeriodSeconds: Int?
    public var timeout: TimeInterval = 300
    public init() {}
}

public enum DrainDisposition: Hashable, Sendable {
    case evict
    case skipDaemonSet
    case skipMirror
    case terminating
    /// Needs `--delete-emptydir-data`.
    case blockedEmptyDir
    /// Needs `--force`.
    case blockedUnmanaged
    /// A DaemonSet pod while "ignore DaemonSets" is off.
    case blockedDaemonSet

    public var isBlocker: Bool { switch self { case .blockedEmptyDir, .blockedUnmanaged, .blockedDaemonSet: true; default: false } }
    public var willEvict: Bool { self == .evict }
}

public struct DrainPodPlan: Identifiable, Hashable, Sendable {
    public var namespace: String
    public var name: String
    public var uid: String?
    public var disposition: DrainDisposition
    public var usesEmptyDir: Bool
    public var controller: String?
    /// Names of PodDisruptionBudgets that currently allow zero disruptions for this pod.
    public var blockingBudgets: [String]
    public var id: String { "\(namespace)/\(name)" }
}

public struct DrainPlan: Hashable, Sendable {
    public var node: String
    public var pods: [DrainPodPlan]
    public var toEvict: [DrainPodPlan] { pods.filter { $0.disposition.willEvict } }
    /// Pods already being deleted; the drain waits for them to disappear.
    public var terminating: [DrainPodPlan] { pods.filter { $0.disposition == .terminating } }
    public var skipped: [DrainPodPlan] { pods.filter { $0.disposition == .skipDaemonSet || $0.disposition == .skipMirror } }
    public var blockers: [DrainPodPlan] { pods.filter { $0.disposition.isBlocker } }
    public var emptyDirPods: [DrainPodPlan] { pods.filter(\.usesEmptyDir) }
    public var pdbWaiting: [DrainPodPlan] { toEvict.filter { !$0.blockingBudgets.isEmpty } }
    public var canProceed: Bool { blockers.isEmpty }
}

public enum DrainPlanner {
    /// Classifies the pods on a node the way `kubectl drain` does.
    public static func plan(node: String, pods: [Pod], budgets: [PodDisruptionBudget], options: DrainOptions) -> DrainPlan {
        var entries: [DrainPodPlan] = []
        for pod in pods where pod.spec.nodeName == node {
            let ns = pod.metadata.namespace ?? "default"
            let controller = pod.metadata.controller
            let usesEmptyDir = pod.spec.volumes.contains { $0.emptyDir != nil }
            let finished = pod.status?.phase == "Succeeded" || pod.status?.phase == "Failed"
            var d: DrainDisposition = .evict
            if pod.metadata.annotations["kubernetes.io/config.mirror"] != nil {
                d = .skipMirror
            } else if controller?.kind == "DaemonSet" {
                d = options.ignoreDaemonSets ? .skipDaemonSet : .blockedDaemonSet
            } else if pod.metadata.deletionTimestamp != nil {
                d = .terminating
            } else if finished {
                d = .evict
            } else if controller == nil && !options.forceUnmanaged {
                d = .blockedUnmanaged
            } else if usesEmptyDir && !options.deleteEmptyDirData {
                d = .blockedEmptyDir
            }
            let blocking = budgets.filter { b in
                b.metadata.namespace == ns && (b.status?.disruptionsAllowed ?? 1) == 0 && b.spec?.selector != nil
                    && LabelSelectorSyntax.matches(b.spec?.selector, labels: pod.metadata.labels)
            }.map(\.metadata.name)
            entries.append(DrainPodPlan(namespace: ns, name: pod.metadata.name, uid: pod.metadata.uid, disposition: d, usesEmptyDir: usesEmptyDir,
                                        controller: controller.map { "\($0.kind)/\($0.name)" }, blockingBudgets: blocking))
        }
        entries.sort { ($0.namespace, $0.name) < ($1.namespace, $1.name) }
        return DrainPlan(node: node, pods: entries)
    }
}

public enum DrainPodState: Hashable, Sendable {
    case pending
    case evicting
    case terminating
    case gone
    case blocked(String)
    case failed(String)
}

public struct DrainPodProgress: Identifiable, Hashable, Sendable {
    public var namespace: String
    public var name: String
    public var uid: String?
    public var state: DrainPodState
    public var attempts = 0
    public var id: String { "\(namespace)/\(name)" }
    public var isFinished: Bool { switch state { case .gone, .failed: true; default: false } }
}

public enum DrainPhase: Hashable, Sendable {
    case idle, cordoning, draining, completed, cancelled, timedOut
    case failed(String)
    public var isRunning: Bool { self == .cordoning || self == .draining }
}

/// Cordons a node and evicts its pods through the Eviction API, retrying while PodDisruptionBudgets block (HTTP 429).
/// Runs only while the app is in the foreground (the owning sheet cancels it on dismiss).
@MainActor @Observable
public final class DrainRunner {
    public private(set) var phase: DrainPhase = .idle
    public private(set) var pods: [DrainPodProgress]
    public private(set) var startedAt: Date?
    public let node: String
    private let client: any KubeClientProtocol
    private let options: DrainOptions
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(client: any KubeClientProtocol, plan: DrainPlan, options: DrainOptions) {
        self.client = client
        self.node = plan.node
        self.options = options
        // Terminating pods are tracked too: the node isn't drained until they are really gone.
        self.pods = plan.pods.filter { $0.disposition.willEvict || $0.disposition == .terminating }
            .map { DrainPodProgress(namespace: $0.namespace, name: $0.name, uid: $0.uid, state: $0.disposition == .terminating ? .terminating : .pending) }
    }

    public var finishedCount: Int { pods.filter(\.isFinished).count }
    public var progress: Double { pods.isEmpty ? (phase == .completed ? 1 : 0) : Double(finishedCount) / Double(pods.count) }

    public func start() {
        guard task == nil else { return }
        startedAt = Date()
        task = Task { [weak self] in await self?.run() }
    }

    /// Stops evicting. The node stays cordoned.
    public func cancel() {
        task?.cancel()
        if phase.isRunning { phase = .cancelled }
    }

    private func set(_ i: Int, _ state: DrainPodState) { pods[i].state = state }

    private func run() async {
        phase = .cordoning
        do { try await client.setNodeUnschedulable(name: node, unschedulable: true) }
        catch {
            phase = .failed((error as? KubeError)?.summary ?? error.localizedDescription)
            return
        }
        phase = .draining
        let deadline = Date().addingTimeInterval(options.timeout)
        var nextAttempt: [String: Date] = [:]
        while !Task.isCancelled {
            for i in pods.indices {
                if Task.isCancelled { return }
                switch pods[i].state {
                case .pending, .blocked: break
                default: continue
                }
                if let when = nextAttempt[pods[i].id], when > Date() { continue }
                set(i, .evicting)
                pods[i].attempts += 1
                do {
                    try await client.evict(pod: pods[i].name, namespace: pods[i].namespace, gracePeriodSeconds: options.gracePeriodSeconds)
                    set(i, .terminating)
                } catch KubeError.notFound {
                    set(i, .gone)
                } catch KubeError.conflict {
                    set(i, .terminating)
                } catch KubeError.server(let status) where status.code == 429 {
                    set(i, .blocked("Blocked by PodDisruptionBudget — retrying"))
                    nextAttempt[pods[i].id] = Date().addingTimeInterval(5)
                } catch KubeError.cancelled {
                    // A cancelled request without a cancelled task (e.g. the session was torn down) must not leave the phase on .draining.
                    if Task.isCancelled { return }
                    set(i, .failed("Cancelled"))
                } catch {
                    set(i, .failed((error as? KubeError)?.summary ?? error.localizedDescription))
                }
            }
            await refreshTerminating()
            if pods.allSatisfy(\.isFinished) { break }
            if Date() >= deadline { phase = .timedOut; return }
            try? await Task.sleep(for: .seconds(2))
        }
        if Task.isCancelled { if phase.isRunning { phase = .cancelled }; return }
        let failures = pods.filter { if case .failed = $0.state { true } else { false } }.count
        phase = failures > 0 ? .failed("\(failures) pod\(failures == 1 ? "" : "s") could not be evicted") : .completed
    }

    private func refreshTerminating() async {
        guard pods.contains(where: { $0.state == .terminating }) else { return }
        guard let live = try? await client.list(Pod.self, options: ListOptions(fieldSelector: "spec.nodeName=\(node)")) else { return }
        let present = Set(live.items.map { "\($0.metadata.namespace ?? "")/\($0.metadata.name)|\($0.metadata.uid ?? "")" })
        for i in pods.indices where pods[i].state == .terminating {
            if !present.contains("\(pods[i].id)|\(pods[i].uid ?? "")") { set(i, .gone) }
        }
    }
}
