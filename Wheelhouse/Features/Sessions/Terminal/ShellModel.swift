import SwiftUI
import WheelhouseKit

/// Creates the terminal surface. SwiftTerm becomes a drop-in once its plugin is trusted: add a `SwiftTermSurface: TerminalSurface`
/// adapter and return it here; nothing else in the Sessions feature depends on the renderer.
@MainActor
enum TerminalSurfaceFactory {
    static func make() -> any TerminalSurface { BasicTerminalSurface() }
}

/// State and plumbing of one interactive shell: owns the surface and the ``ExecSession``.
@MainActor @Observable
final class ShellModel: Identifiable, TerminalSurfaceDelegate {
    enum Phase: Equatable {
        case awaitingConfirmation
        case preparing
        case connecting
        case connected
        case ended(exit: Int?, message: String?)
        case disconnected(String?)
        case unavailable(Unavailable)
    }

    enum Unavailable: Equatable {
        case demo
        case readOnly
        case forbidden(String)
        case notRunning(container: String, state: String, siblings: [String])
        case failed(String)
    }

    let id = UUID()
    let pod: ResourceRef
    let startedAt = Date()
    let requestedContainer: String?
    private(set) var container: String?
    private(set) var containers: [String] = []
    var shell: ShellChoice = .auto
    private(set) var phase: Phase = .preparing
    private(set) var protocolName: String?
    let surface: any TerminalSurface = TerminalSurfaceFactory.make()
    let clusterSession: ClusterSession

    @ObservationIgnored private var exec: ExecSession?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var cols = 0
    @ObservationIgnored private var rows = 0
    @ObservationIgnored private var wantsStart = false
    @ObservationIgnored private var receivedOutput = false
    @ObservationIgnored private var fellBack = false
    @ObservationIgnored private var connectStarted = Date()

    init(pod: ResourceRef, container: String?, session: ClusterSession) {
        self.pod = pod
        self.requestedContainer = container
        self.container = container
        self.clusterSession = session
        surface.delegate = self
    }

    var isLive: Bool { if case .connected = phase { true } else if case .connecting = phase { true } else { false } }
    var title: String { "\(container ?? pod.name) · \(shell.shortName)" }
    var canReconnect: Bool { switch phase { case .ended, .disconnected: true; default: false } }

    // MARK: Preparation

    func awaitConfirmation() { phase = .awaitingConfirmation }

    /// Checks cluster mode, pod and container state, then connects.
    func prepareAndConnect() async {
        phase = .preparing
        let config = clusterSession.config
        if config.isDemo { phase = .unavailable(.demo); return }
        if config.readOnly && !config.allowExecInReadOnly { phase = .unavailable(.readOnly); return }
        guard let namespace = pod.namespace else { phase = .unavailable(.failed("This pod has no namespace.")); return }
        do {
            let p = try await clusterSession.client.get(Pod.self, name: pod.name, namespace: namespace)
            containers = p.spec.containers.map(\.name)
            let preferred = container ?? p.metadata.annotations["kubectl.kubernetes.io/default-container"] ?? containers.first
            container = preferred
            if let name = preferred {
                let status = p.status?.containerStatuses.first { $0.name == name }
                if status?.state?.running == nil {
                    let state = Self.describe(status: status, phase: p.status?.phase)
                    let siblings = await readySiblings(of: p, namespace: namespace)
                    phase = .unavailable(.notRunning(container: name, state: state, siblings: siblings))
                    return
                }
            }
        } catch let e as KubeError {
            switch e {
            case .notFound: phase = .unavailable(.failed("The pod no longer exists.")); return
            case .unauthorized, .unreachable, .tlsUntrusted: phase = .unavailable(.failed(e.summary)); return
            default: break // e.g. forbidden to read pods: still try exec
            }
        } catch {}
        connect()
    }

    private static func describe(status: ContainerStatus?, phase: String?) -> String {
        if let w = status?.state?.waiting { return "waiting (\(w.reason ?? "Waiting"))" }
        if let t = status?.state?.terminated { return "terminated (\(t.reason ?? "Exited"), exit \(t.exitCode))" }
        if let phase, phase != "Running" { return phase }
        return "not running"
    }

    private func readySiblings(of pod: Pod, namespace: String) async -> [String] {
        guard let owner = pod.metadata.controller else { return [] }
        guard let list = try? await clusterSession.client.list(Pod.self, namespace: namespace) else { return [] }
        return list.items.filter { other in
            other.metadata.name != pod.metadata.name && other.metadata.controller?.uid == owner.uid &&
            other.status?.phase == "Running" && other.readyContainers == other.totalContainers && other.metadata.deletionTimestamp == nil
        }.map(\.metadata.name).sorted()
    }

    // MARK: Connection

    func connect() {
        teardownSocket()
        receivedOutput = false
        connectStarted = Date()
        phase = .connecting
        if cols > 1 { startExec() } else { wantsStart = true }
    }

    func reconnect() {
        surface.feed("\r\n\u{1B}[2m── reconnecting ──\u{1B}[0m\r\n")
        Task { await prepareAndConnect() }
    }

    private func startExec() {
        wantsStart = false
        let options = ExecOptions(container: container, command: shell.command, tty: true, stdin: true)
        let session = ExecSession(client: clusterSession.client, namespace: pod.namespace ?? "default", pod: pod.name, options: options)
        exec = session
        eventTask = Task { [weak self] in
            for await event in session.events { self?.handle(event) }
        }
        let (c, r) = (cols, rows)
        Task {
            do { try await session.start(cols: c, rows: r) } catch {
                let kube = (error as? KubeError) ?? .unreachable(cause: error.localizedDescription)
                self.fail(kube)
            }
        }
    }

    private func fail(_ error: KubeError) {
        switch error {
        case .unsupported: phase = .unavailable(.demo)
        case .readOnly: phase = .unavailable(.readOnly)
        case .forbidden(_, _, _, let message): phase = .unavailable(.forbidden(message))
        default: phase = .disconnected(error.summary)
        }
    }

    private func handle(_ event: ExecEvent) {
        switch event {
        case .opened(let proto):
            protocolName = proto
            phase = .connected
            let podLine = "\(pod.name) · \(container ?? "default") · \(shell.shortName)"
            surface.feed("\u{1B}[2m\(podLine) · \(proto ?? "channel protocol") · \(cols)×\(rows)\u{1B}[0m\r\n")
        case .output(let data):
            receivedOutput = true
            surface.feed(data)
        case .exited(let status):
            if tryShellFallback(status) { return }
            phase = .ended(exit: status.exitCode, message: status.outcome == .success ? nil : status.message)
        case .closed(let error):
            if case .ended = phase { return }
            if case .unavailable = phase { return }
            if let error {
                if case .forbidden(_, _, _, let message) = error { phase = .unavailable(.forbidden(message)) } else { phase = .disconnected(error.summary) }
            } else if case .connected = phase { phase = .disconnected(nil) }
        }
    }

    /// `/bin/bash` missing → retry once with `/bin/sh`.
    private func tryShellFallback(_ status: ExecStatus) -> Bool {
        guard !fellBack, !receivedOutput, shell == .bash, Date().timeIntervalSince(connectStarted) < 5 else { return false }
        let missing: Bool
        switch status.outcome {
        case .exited(let code): missing = code == 126 || code == 127
        case .failure: missing = (status.message ?? "").localizedCaseInsensitiveContains("no such file") || (status.message ?? "").localizedCaseInsensitiveContains("not found")
        case .success: missing = false
        }
        guard missing else { return false }
        fellBack = true
        shell = .sh
        surface.feed("\u{1B}[33mbash is not available in this container; falling back to /bin/sh\u{1B}[0m\r\n")
        connect()
        return true
    }

    private func teardownSocket() {
        eventTask?.cancel(); eventTask = nil
        if let exec { Task { await exec.close() } }
        exec = nil
    }

    func close() {
        teardownSocket()
        if case .unavailable = phase {} else { phase = .ended(exit: nil, message: "Closed") }
    }

    func appWillEnterForeground() {
        // The socket usually died while suspended; the read loop reports it. Nothing to do if still connected.
    }

    // MARK: Settings

    func setShell(_ choice: ShellChoice) {
        guard choice != shell else { return }
        shell = choice
        fellBack = false
        surface.feed("\r\n\u{1B}[2m── switching to \(choice.shortName) ──\u{1B}[0m\r\n")
        Task { await prepareAndConnect() }
    }

    func setContainer(_ name: String) {
        guard name != container else { return }
        container = name
        surface.reset()
        Task { await prepareAndConnect() }
    }

    func openSibling(_ podName: String) -> ResourceRef {
        ResourceRef(clusterID: pod.clusterID, kind: .pod, namespace: pod.namespace, name: podName)
    }

    // MARK: TerminalSurfaceDelegate

    func terminalSurface(_ surface: any TerminalSurface, send data: Data) {
        guard let exec, isLive else { return }
        Task { await exec.send(data) }
    }

    func terminalSurface(_ surface: any TerminalSurface, didResize cols: Int, rows: Int) {
        self.cols = cols; self.rows = rows
        if wantsStart, phase == .connecting { startExec(); return }
        if let exec { Task { await exec.resize(cols: cols, rows: rows) } }
    }
}
