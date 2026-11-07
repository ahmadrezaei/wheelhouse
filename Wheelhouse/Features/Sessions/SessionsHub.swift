import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// One finished session kept in the "Recent" list (in memory only).
struct RecentSession: Identifiable {
    enum Kind { case shell, logs, forward }
    let id = UUID()
    var kind: Kind
    var title: String
    var subtitle: String
    var endedAt: Date
    var route: Route?
}

/// App-wide registry of live sessions: port-forwards, shells and followed log streams. Views of the Sessions feature read
/// from it so a shell or log stream keeps running while you navigate elsewhere and can be resumed from the Sessions tab.
///
/// iOS suspends apps shortly after they leave the foreground: forwards release their sockets and come back on return,
/// log streams reconnect (deduplicated), shells report "disconnected" and offer Reconnect.
@MainActor @Observable
final class SessionsHub {
    static let shared = SessionsHub()

    let manager = PortForwardManager()
    private(set) var forwards: [PortForwardInfo] = []
    private(set) var shells: [ShellModel] = []
    private(set) var logModels: [LogsModel] = []
    private(set) var recents: [RecentSession] = []
    /// Set by the Sessions tab right before it navigates, so the shell screen resumes that exact session.
    var resumeShellID: UUID?
    var resumeLogsID: UUID?
    private(set) var isBackgrounded = false

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    /// Foreground/background transitions, consumed one at a time so pause and resume can never run out of order.
    @ObservationIgnored private let lifecycleEvents = AsyncStream<Bool>.makeStream(bufferingPolicy: .unbounded)
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?

    private init() {
        let center = NotificationCenter.default
        // iOS: background / foreground. Mac: only sleep and wake (the Mac does not suspend sessions on deactivate).
        observers.append(contentsOf: PlatformLifecycle.observe(
            suspend: { [weak self] in self?.appDidEnterBackground() },
            resume: { [weak self] in self?.appWillEnterForeground() }))
        observers.append(center.addObserver(forName: ClusterEvents.invalidated, object: nil, queue: .main) { [weak self] note in
            guard let id = ClusterEvents.clusterID(from: note) else { return }
            let removed = ClusterEvents.wasRemoved(note)
            MainActor.assumeIsolated { self?.clusterInvalidated(id, removed: removed) }
        })
        let manager = manager
        lifecycleTask = Task {
            for await foreground in lifecycleEvents.stream {
                if foreground { await manager.resumeAll() } else { await manager.pauseAll() }
            }
        }
        updatesTask = Task { [weak self] in
            for await snapshot in await manager.updates() {
                // Equal snapshots must not invalidate every observing screen (the manager ticks while a forward is live).
                if let self, self.forwards != snapshot { self.forwards = snapshot }
            }
        }
    }

    // MARK: Counts

    var liveForwardCount: Int { forwards.filter { $0.state.isLive }.count }
    var activeCount: Int { liveForwardCount + shells.count + logModels.count }
    var hasAnySession: Bool { !forwards.isEmpty || !shells.isEmpty || !logModels.isEmpty }

    // MARK: Lifecycle

    private func appDidEnterBackground() {
        isBackgrounded = true
        lifecycleEvents.continuation.yield(false)
        for log in logModels { log.appDidEnterBackground() }
    }

    private func appWillEnterForeground() {
        isBackgrounded = false
        lifecycleEvents.continuation.yield(true)
        for log in logModels { log.appWillEnterForeground() }
        for shell in shells { shell.appWillEnterForeground() }
    }

    // MARK: Cluster changes

    /// A cluster was edited or removed: everything bound to its old client (credentials, read-only flag, server) is dropped.
    /// Forwards are stopped (and removed with the cluster), shells and log streams are closed.
    private func clusterInvalidated(_ clusterID: ClusterID, removed: Bool) {
        let affectedForwards = forwards.filter { $0.clusterID == clusterID }.map(\.id)
        Task {
            await manager.stopAll(clusterID: clusterID)
            if removed { for id in affectedForwards { await manager.remove(id) } }
        }
        if removed { forwards.removeAll { $0.clusterID == clusterID } }
        for shell in shells where shell.pod.clusterID == clusterID {
            shell.close()
            if !removed { recordRecent(shell) }
        }
        shells.removeAll { $0.pod.clusterID == clusterID }
        for logs in logModels where logs.pod.clusterID == clusterID {
            logs.stop()
            if !removed { recordRecent(logs) }
        }
        logModels.removeAll { $0.pod.clusterID == clusterID }
        if resumeShellID.flatMap({ id in shell(id: id) }) == nil { resumeShellID = nil }
        if resumeLogsID.flatMap({ id in logs(id: id) }) == nil { resumeLogsID = nil }
    }

    // MARK: Shells

    func shell(id: UUID) -> ShellModel? { shells.first { $0.id == id } }

    func existingShell(for pod: ResourceRef, container: String?) -> ShellModel? {
        if let id = resumeShellID, let s = shell(id: id) { resumeShellID = nil; return s }
        return shells.last { $0.pod == pod && (container == nil || $0.container == container || $0.requestedContainer == container) }
    }

    func register(_ shell: ShellModel) { if !shells.contains(where: { $0.id == shell.id }) { shells.append(shell) } }

    func close(_ shell: ShellModel) {
        shell.close()
        shells.removeAll { $0.id == shell.id }
        recordRecent(shell)
    }

    private func recordRecent(_ shell: ShellModel) {
        recents.insert(RecentSession(kind: .shell, title: "Shell · \(shell.pod.name)", subtitle: "\(shell.container ?? "container") · \(shell.shell.shortName)",
                                     endedAt: Date(), route: .shell(shell.pod, container: shell.container)), at: 0)
        trimRecents()
    }

    // MARK: Logs

    func logs(id: UUID) -> LogsModel? { logModels.first { $0.id == id } }

    func existingLogs(for pod: ResourceRef, container: String?, previous: Bool) -> LogsModel? {
        if let id = resumeLogsID, let m = logs(id: id) { resumeLogsID = nil; return m }
        return logModels.last { $0.pod == pod && $0.previous == previous && (container == nil || $0.container == container || $0.requestedContainer == container) }
    }

    func register(_ logs: LogsModel) {
        guard !logModels.contains(where: { $0.id == logs.id }) else { return }
        logModels.append(logs)
        // Follow connections are capped globally by `LogFollowRegistry` (older streams are suspended, never evicted).
    }

    func close(_ logs: LogsModel) {
        logs.stop()
        logModels.removeAll { $0.id == logs.id }
        recordRecent(logs)
    }

    private func recordRecent(_ logs: LogsModel) {
        recents.insert(RecentSession(kind: .logs, title: "Logs · \(logs.pod.name)", subtitle: "\(logs.container ?? "default container")\(logs.previous ? " · previous" : "")",
                                     endedAt: Date(), route: .logs(logs.pod, container: logs.container, previous: logs.previous)), at: 0)
        trimRecents()
    }

    // MARK: Port-forwards

    @discardableResult
    func startForward(session: ClusterSession, target: PortForwardTarget, localPort: Int) async throws -> PortForwardInfo {
        let info = try await manager.start(clusterID: session.id, clusterName: session.config.name, client: session.client, target: target, localPort: localPort,
                                       readOnly: session.config.readOnly, allowExecInReadOnly: session.config.allowExecInReadOnly)
        return info
    }

    func stopForward(_ id: UUID) {
        guard let info = forwards.first(where: { $0.id == id }) else { return }
        Task {
            await manager.stop(id)
            await manager.remove(id)
        }
        recents.insert(RecentSession(kind: .forward, title: info.target.title, subtitle: "localhost:\(info.localPort) · \(info.clusterName) · ↓\(Self.bytes(info.bytesDown)) ↑\(Self.bytes(info.bytesUp))",
                                     endedAt: Date(), route: .portForward(ResourceRef(clusterID: info.clusterID, kind: info.target.kind == .service ? .service : .pod,
                                                                                      namespace: info.target.namespace, name: info.target.name))), at: 0)
        forwards.removeAll { $0.id == id }
        trimRecents()
    }

    func forward(id: UUID) -> PortForwardInfo? { forwards.first { $0.id == id } }

    func clearRecents() { recents.removeAll() }

    private func trimRecents() { if recents.count > 20 { recents.removeLast(recents.count - 20) } }

    static func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary) }
}

/// "Can I do this?" check used as the dry-run step before opening a shell or a port-forward on a production cluster.
enum SessionAccessCheck {
    static func canCreate(_ client: any KubeClientProtocol, namespace: String, pod: String?, subresource: String) async -> DryRunOutcomeValue {
        var attrs: [String: JSONValue] = ["namespace": .string(namespace), "verb": "create", "resource": "pods", "subresource": .string(subresource)]
        if let pod { attrs["name"] = .string(pod) }
        let body: JSONValue = ["apiVersion": "authorization.k8s.io/v1", "kind": "SelfSubjectAccessReview", "spec": ["resourceAttributes": .object(attrs)]]
        do {
            let result = try await client.create(.selfSubjectAccessReview, namespace: nil, name: nil, subresource: nil, body: body, options: MutationOptions())
            if result.value(at: "status.allowed") == .bool(true) { return .allowed }
            let reason = result.value(at: "status.reason").flatMap { if case .string(let s) = $0 { s } else { nil } }
            return .denied(reason ?? "The API server says you cannot create pods/\(subresource) in \(namespace).")
        } catch let e as KubeError {
            if case .unsupported = e { return .allowed }
            return .unknown(e.summary)
        } catch { return .unknown(error.localizedDescription) }
    }

    enum DryRunOutcomeValue { case allowed, denied(String), unknown(String) }
}
