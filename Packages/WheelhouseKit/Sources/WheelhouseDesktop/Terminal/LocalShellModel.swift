#if os(macOS)
import Darwin
import Dispatch
import Foundation
import Observation
import WheelhouseKit

/// What the banner above a Deck Terminal says.
public enum ShellBanner: Equatable, Sendable {
    case starting
    /// "kubectl and helm changes need confirmation."
    case guarded
    /// The shell has started but no verified prompt mark has arrived yet.
    case awaitingMarks
    /// The shell printed marks it could not have written; confirmations are per request.
    case perRequest(String)
    /// KUBECONFIG changed, a command carries bypass flags, or the session file changed. `Restore` is offered.
    case unguarded(String)
    /// The shell no longer reports (`exec bash`, `su`, an ssh session): KUBECONFIG is not verified.
    case integrationLost
    /// A shell without integration (not zsh, bash or fish): every change gets a per-request sheet.
    case noIntegration
    /// Direct mode: no guard at all, on purpose.
    case direct
    /// The session ended (app lock, cluster removed, quit).
    case sessionEnded(String)
    case ended
}

public enum ShellPhase: Equatable, Sendable {
    case notStarted
    case running
    case exited(Int?)
}

/// Where the shell is in its prompt cycle, from verified marks only.
public enum ShellCommandState: Equatable, Sendable {
    case unknown
    case prompt
    case running
}

public enum RestoreAction: Equatable, Sendable {
    /// `export KUBECONFIG=…` was placed at the prompt (not run): press Return.
    case inserted
    /// The session ended or its file changed: open a new guarded shell.
    case needsNewShell
    case refused(String)
}

/// One Deck Terminal's local shell (ARCHITECTURE-MAC section 3.4): the PTY, the Gangway session, and everything learned from the shell's
/// verified marks. It knows nothing about SwiftUI or AppKit: the pane feeds its output into a terminal view through ``onOutput``.
///
/// Nothing here polls. The pane title and the prompt state come from marks, "is something running?" is asked once at close time with
/// `tcgetpgrp`, and the shell's exit comes from the PTY's process-exit source.
@MainActor @Observable
public final class LocalShellModel: TerminalInsertTarget {
    public enum Mode: Equatable, Sendable { case guarded, direct }

    public struct Configuration {
        public var cluster: ClusterConfig
        public var namespace: String?
        public var shell: URL
        public var startDirectory: URL?
        public var mode: Mode
        public var paneID: String
        public var size: (cols: Int, rows: Int)
        /// The user's shell environment (or the few base variables). `KUBECONFIG` and friends are removed by ``TerminalEnvironment``.
        public var baseEnvironment: [String: String]
        public var helmEnvironment: [String: String]
        /// Where the user's startup files are read from. An empty folder while development safety is active.
        public var userFiles: ShellIntegration.UserFiles
        /// Replaces `HOME` (development builds and tests: an empty folder).
        public var home: URL?
        public var kubeCacheDir: URL
        /// Direct mode only: the cluster's own kubeconfig context and the folder for its single-context file.
        public var directContext: KubeconfigContext?
        public var directRoot: URL
        public var helper: URL
        public var gate: DevSafetyPolicy
        public var activity: any ActivityLogging

        public init(cluster: ClusterConfig, namespace: String? = nil, shell: URL, startDirectory: URL? = nil, mode: Mode = .guarded, paneID: String = UUID().uuidString,
                    size: (cols: Int, rows: Int) = (100, 30), baseEnvironment: [String: String], helmEnvironment: [String: String] = [:],
                    userFiles: ShellIntegration.UserFiles, home: URL? = nil, kubeCacheDir: URL, directContext: KubeconfigContext? = nil,
                    directRoot: URL, helper: URL = PTYProcess.bundledHelper, gate: DevSafetyPolicy = .current, activity: any ActivityLogging = NoopActivityLog()) {
            self.cluster = cluster
            self.namespace = namespace
            self.shell = shell
            self.startDirectory = startDirectory
            self.mode = mode
            self.paneID = paneID
            self.size = size
            self.baseEnvironment = baseEnvironment
            self.helmEnvironment = helmEnvironment
            self.userFiles = userFiles
            self.home = home
            self.kubeCacheDir = kubeCacheDir
            self.directContext = directContext
            self.directRoot = directRoot
            self.helper = helper
            self.gate = gate
            self.activity = activity
        }
    }

    public static let forgedLimit = 3
    public static let forgedMessage = "This shell printed fake Wheelhouse markers; command confirmations are now per request"

    public let configuration: Configuration
    public private(set) var banner: ShellBanner = .starting
    public private(set) var phase: ShellPhase = .notStarted
    public private(set) var commandState: ShellCommandState = .unknown
    public private(set) var currentCommand: String?
    public private(set) var workingDirectory: String?
    public private(set) var forgedMarks = 0
    /// The shell kind of the running session.
    public private(set) var kind: ShellKind = .other
    /// Text arriving from the shell; set by the pane that owns the terminal view. Output that arrives before it is set is kept (bounded).
    @ObservationIgnored public var onOutput: (@MainActor (Data) -> Void)? {
        didSet { flushPending() }
    }
    /// DECSET 2004 as the terminal view tracks it.
    @ObservationIgnored public var bracketedPasteProvider: (@MainActor () -> Bool)?

    @ObservationIgnored private var pty: PTYProcess?
    @ObservationIgnored private var gangway: GangwayService?
    @ObservationIgnored private var handle: GangwaySessionHandle?
    @ObservationIgnored private var directDirectory: URL?
    @ObservationIgnored private var nonce: String?
    @ObservationIgnored private var scanner = OSCScanner()
    @ObservationIgnored private var pending: [Data] = []
    @ObservationIgnored private var pendingBytes = 0
    @ObservationIgnored private var pendingLine: String?
    @ObservationIgnored private var runningCommandID: String?
    @ObservationIgnored private var perRequestReason: String?
    @ObservationIgnored private var seenVerified = false
    @ObservationIgnored private var reportedKubeconfig: String??
    @ObservationIgnored private var bypassReason: String?
    @ObservationIgnored private var integrityReason: String?
    @ObservationIgnored private var integrationLost = false
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var closed = false

    public init(configuration: Configuration) { self.configuration = configuration }

    // MARK: Start and stop

    public var sessionKubeconfig: URL? { handle?.kubeconfig }
    public var ptyProcessID: pid_t? { pty?.pid }
    /// The nonce of the running session; tests forge and verify marks with it.
    var verificationNonce: String? { nonce }
    var gangwaySession: GangwaySession? { handle?.session }
    public var isDirect: Bool { configuration.mode == .direct }

    /// Opens the Gangway session (guarded) or writes the single-context file (direct), starts the shell, and begins reading it.
    public func start(gangway service: GangwayService?) async throws {
        guard phase == .notStarted else { return }
        let session = UUID().uuidString.lowercased()
        let cfg = configuration
        switch cfg.mode {
        case .guarded:
            guard let service else { throw SessionKubeconfigError.writeFailed("Gangway is not available") }
            let handle = try await service.openSession(clusterID: cfg.cluster.id, origin: .terminal(paneID: cfg.paneID), namespace: cfg.namespace)
            do {
                let nonce = ShellNonce.make()
                let launch = try ShellIntegration.prepare(shell: cfg.shell, directory: handle.directory, nonce: nonce, kubeconfig: handle.kubeconfig, user: cfg.userFiles)
                try spawn(launch: launch, kubeconfig: handle.kubeconfig, sessionID: handle.session.id.uuidString.lowercased())
                self.gangway = service
                self.handle = handle
                self.nonce = launch.integrated ? nonce : nil
                kind = launch.kind
                // Bound right after the spawn, before anything suspends: until then every request gets its own sheet.
                if let pty { handle.session.bind(.pty(device: pty.ttyDevice, session: pty.pid, foreground: { [weak pty] in pty?.foregroundProcessGroup })) }
                watch(handle.kubeconfig)
            } catch {
                service.closeSession(handle, reason: "the shell could not be started")
                throw error
            }
        case .direct:
            guard let context = cfg.directContext else { throw SessionKubeconfigError.writeFailed("No kubeconfig context for Direct mode") }
            let avail = DirectKubeconfig.availability(for: cfg.cluster, hasKubeconfigContext: true, gate: cfg.gate)
            if case .unavailable(let why) = avail { throw SessionKubeconfigError.writeFailed(why) }
            let written = try DirectKubeconfig.write(context, root: cfg.directRoot)
            directDirectory = written.directory
            let plain = ShellLaunch(executable: cfg.shell, arguments: ["-l"], environment: [:], kind: ShellKind(path: cfg.shell.path), integrated: false)
            do { try spawn(launch: plain, kubeconfig: written.file, sessionID: session) } catch {
                DirectKubeconfig.remove(directory: written.directory)
                directDirectory = nil
                throw error
            }
            kind = .other
        }
        phase = .running
        refreshBanner()
        startPumps()
    }

    private func spawn(launch: ShellLaunch, kubeconfig: URL, sessionID: String) throws {
        let cfg = configuration
        let built = TerminalEnvironment.build(base: cfg.baseEnvironment, kubeconfig: kubeconfig, kubeCacheDir: cfg.kubeCacheDir,
                                              session: .init(clusterID: cfg.cluster.id, clusterName: cfg.cluster.name, environmentName: cfg.cluster.environment.rawValue, sessionID: sessionID),
                                              helm: cfg.helmEnvironment, home: cfg.home)
        var env = built.environment
        env.merge(launch.environment) { _, new in new }
        // A missing start directory makes the spawn fail: fall back to the home directory.
        var directory = cfg.startDirectory
        var isDirectory: ObjCBool = false
        if let d = directory, !(FileManager.default.fileExists(atPath: d.path, isDirectory: &isDirectory) && isDirectory.boolValue) { directory = nil }
        let spec = ProcessSpec(executable: launch.executable, arguments: launch.arguments, environment: env, currentDirectory: directory ?? cfg.home ?? URL(fileURLWithPath: env["HOME"] ?? "/"),
                               timeout: .seconds(365 * 24 * 3600))
        pty = try PTYProcess(spec: spec, size: cfg.size, helper: cfg.helper)
    }

    private func startPumps() {
        guard let pty else { return }
        tasks.append(Task { [weak self] in
            for await chunk in pty.output { self?.receive(chunk) }
        })
        tasks.append(Task { [weak self] in
            let exit = await pty.waitForExit()
            self?.shellExited(exit.code.map(Int.init))
        })
    }

    private func shellExited(_ code: Int?) {
        guard phase == .running else { return }
        phase = .exited(code)
        teardown(reason: "the shell exited")
        refreshBanner()
    }

    /// Ends the shell (SIGHUP to its group, SIGKILL after 2 s), revokes the session and deletes its files.
    public func close() async {
        guard !closed else { return }
        closed = true
        if let pty { await pty.terminate() }
        if phase == .running { phase = .exited(nil) }
        teardown(reason: "the terminal was closed")
        refreshBanner()
    }

    private func teardown(reason: String) {
        watcher?.cancel()
        watcher = nil
        tasks.forEach { $0.cancel() }
        tasks = []
        if let handle, let gangway {
            gangway.closeSession(handle, reason: reason)
            SessionKubeconfigWriter.remove(directory: handle.directory)
        }
        if let directDirectory { DirectKubeconfig.remove(directory: directDirectory) }
        directDirectory = nil
    }

    // MARK: Input

    /// What the person typed (or pasted). A Return while the last verified mark says a command is running, with the shell itself in the
    /// foreground, means the shell stopped reporting.
    public func write(_ data: Data) {
        guard let pty else { return }
        if nonce != nil, commandState == .running, data.contains(0x0D), let group = pty.foregroundProcessGroup, group == pty.pid {
            integrationLost = true
            refreshBanner()
        }
        pty.write(data)
    }

    public func resize(cols: Int, rows: Int) { pty?.resize(cols: cols, rows: rows) }

    /// Asked once, when the person closes the pane: is something other than the shell in the foreground?
    public var hasRunningProgram: Bool {
        guard let pty, let group = pty.foregroundProcessGroup else { return false }
        return group != pty.pid
    }

    // MARK: Output and marks

    private func receive(_ chunk: Data) {
        // Marks are cut out of the stream whether or not this shell has integration: the terminal emulator must never see an OSC 133 or 633.
        let scanned = scanner.process(chunk)
        if nonce != nil { for sequence in scanned.sequences { process(sequence) } }
        if !scanned.output.isEmpty { deliver(scanned.output) }
    }

    private func deliver(_ chunk: Data) {
        if let onOutput { onOutput(chunk); return }
        pending.append(chunk)
        pendingBytes += chunk.count
        while pendingBytes > 512 * 1024, let first = pending.first {
            pendingBytes -= first.count
            pending.removeFirst()
        }
    }

    private func flushPending() {
        guard let onOutput, !pending.isEmpty else { return }
        let chunks = pending
        pending = []
        pendingBytes = 0
        chunks.forEach { onOutput($0) }
    }

    /// Handles one 133 or 633 sequence found in the shell's output. Exposed for tests.
    func process(_ sequence: OSCSequence) {
        guard let nonce else { return }
        let parsed = ShellMarkParser.parse(sequence, nonce: nonce)
        guard parsed.authenticity == .verified else {
            forgedMarks += 1
            if forgedMarks >= Self.forgedLimit, perRequestReason == nil { dropToPerRequest() }
            return
        }
        guard let mark = parsed.mark else { return }
        seenVerified = true
        integrationLost = false
        switch mark {
        case .promptStart:
            commandState = .prompt
            endCommand()
            pendingLine = nil
        case .commandLine(let line):
            pendingLine = line
        case .kubeconfig(let value):
            let changed = reportedKubeconfig == nil || reportedKubeconfig! != value
            reportedKubeconfig = .some(value)
            if changed, value != sessionKubeconfig?.path { audit("KUBECONFIG changed in the shell") }
        case .commandExecuted:
            commandState = .running
            startCommand()
        case .commandFinished:
            commandState = .prompt
            endCommand()
        case .workingDirectory(let path):
            workingDirectory = path
        }
        refreshBanner()
    }

    /// Publishes the reported line (or none) as the running command, with a fresh id so the same line twice never shares a grant.
    private func startCommand() {
        guard let session = handle?.session else { return }
        let line = pendingLine
        pendingLine = nil
        currentCommand = line
        bypassReason = line.flatMap(UnguardedDetector.bypassReason(in:))
        if let bypassReason { audit("command bypasses the guard (\(bypassReason))") }
        guard perRequestReason == nil, let line, !line.isEmpty else {
            session.reportedCommand = nil
            runningCommandID = nil
            return
        }
        let command = ReportedCommand(id: UUID().uuidString, line: line)
        runningCommandID = command.id
        session.reportedCommand = command
    }

    private func endCommand() {
        if let session = handle?.session {
            if let id = runningCommandID { gangway?.grants.endCommand(session: session, commandID: id) }
            session.reportedCommand = nil
        }
        runningCommandID = nil
        currentCommand = nil
        bypassReason = nil
    }

    private func dropToPerRequest() {
        perRequestReason = Self.forgedMessage
        if let session = handle?.session {
            session.reportedCommand = nil
            gangway?.grants.revoke(session: session)
        }
        runningCommandID = nil
        audit("fake markers: confirmations are per request")
        refreshBanner()
    }

    // MARK: Banner

    public func refreshBanner() {
        banner = computeBanner()
    }

    private func computeBanner() -> ShellBanner {
        if phase == .notStarted { return .starting }
        if case .exited = phase { return .ended }
        if configuration.mode == .direct { return .direct }
        if let session = handle?.session, session.isRevoked, integrityReason == nil {
            return .sessionEnded(session.revokedReason ?? "the session ended")
        }
        if let integrityReason { return .unguarded(integrityReason) }
        if kind == .other { return .noIntegration }
        if let perRequestReason { return .perRequest(perRequestReason) }
        if let reported = reportedKubeconfig, reported != sessionKubeconfig?.path { return .unguarded("KUBECONFIG was changed in this shell.") }
        if let bypassReason { return .unguarded("This command bypasses Wheelhouse's guard (\(bypassReason)).") }
        if integrationLost { return .integrationLost }
        if !seenVerified { return .awaitingMarks }
        return .guarded
    }

    /// Whether the banner offers Restore.
    public var canRestore: Bool {
        if case .unguarded = banner { return true }
        if case .integrationLost = banner { return true }
        if case .sessionEnded = banner { return true }
        return false
    }

    /// Puts `export KUBECONFIG=<session file>` at the prompt (never runs it) when only the variable changed; otherwise the pane must open a new shell.
    public func restore() -> RestoreAction {
        guard let handle, !handle.session.isRevoked, integrityReason == nil else { return .needsNewShell }
        switch TerminalInserter.insert("export KUBECONFIG=\(ShellIntegration.quoted(handle.kubeconfig.path))", forCluster: nil, into: self) {
        case .inserted: return .inserted
        case .refused(let why): return .refused(why)
        }
    }

    // MARK: Session file

    private func watch(_ file: URL) {
        let fd = open(file.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .attrib], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.checkIntegrity() }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watcher = source
    }

    /// Re-hashes the session kubeconfig. A changed file ends the session (Gangway revokes the token) and turns the banner Unguarded.
    public func checkIntegrity() {
        guard let handle, let gangway, !handle.session.isRevoked else { refreshBanner(); return }
        let result = gangway.verifyIntegrity(handle)
        if result != .intact {
            integrityReason = "The session kubeconfig was changed: this shell's commands are no longer guarded."
            audit("session kubeconfig changed (\(result))")
        }
        refreshBanner()
    }

    private func audit(_ what: String) {
        configuration.activity.record(ActivityEntry(cluster: configuration.cluster.id, origin: .terminal(session: configuration.paneID, reportedCommand: currentCommand),
                                                    verb: "unguarded", object: what, result: "shown"))
    }

    // MARK: TerminalInsertTarget

    public var targetClusterID: ClusterID? { configuration.cluster.id }
    public var targetClusterName: String { configuration.cluster.name }
    public var bracketedPasteEnabled: Bool { bracketedPasteProvider?() ?? false }
    public var isAtPrompt: Bool { phase == .running && commandState == .prompt }
    public func writeToShell(_ data: Data) { pty?.write(data) }
}
#endif
