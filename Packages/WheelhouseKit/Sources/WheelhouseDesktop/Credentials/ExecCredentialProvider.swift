#if os(macOS)
import Foundation
import Synchronization
import WheelhouseKit

/// Runs a plugin and returns what it printed. The default runs the real program through ``Subprocess``; tests inject a fake.
public protocol ExecPluginRunning: Sendable {
    func run(_ spec: ProcessSpec) async throws -> ProcessResult
}

public struct SubprocessPluginRunner: ExecPluginRunning {
    public init() {}
    public func run(_ spec: ProcessSpec) async throws -> ProcessResult { try await Subprocess.run(spec) }
}

/// At most N plugin processes at once (3 by default), so opening a fleet never starts a storm of SSO browser tabs.
public actor ExecConcurrencyLimiter {
    public static let shared = ExecConcurrencyLimiter(limit: 3)
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    public private(set) var peak = 0

    public init(limit: Int) { self.limit = limit }

    public func acquire() async {
        if running < limit {
            running += 1
            peak = max(peak, running)
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    public func release() {
        if !waiting.isEmpty {
            waiting.removeFirst().resume()   // the slot passes to the next waiter
        } else {
            running -= 1
        }
    }
}

/// Caches plugin credentials in MEMORY ONLY, keyed by the exec stanza, the server and the kubeconfig path (ARCHITECTURE-MAC §4.5).
///
/// - A credential is reused until 60 s before it expires (or 80 % of its lifetime when that is sooner); without an expiry, until a 401.
/// - Concurrent callers share one run (single flight); a global limit applies across all keys.
/// - A refresh task exists only for a key that has consumers (a visible, open, pinned or watched cluster).
/// - Nothing is written to disk, the Keychain, logs or Activity (Activity records only "plugin ran: aws, 1.2 s, exit 0").
public actor ExecCredentialBroker {
    struct Entry {
        var credential: ExecCredential
        var obtainedAt: Date
    }

    private let locator: @Sendable () -> ExecutableLocator
    private let environment: @Sendable () -> EnvironmentBuilder
    private let runner: any ExecPluginRunning
    private let limiter: ExecConcurrencyLimiter
    private let activity: any ActivityLogging
    private let gate: DevSafetyPolicy
    private let now: @Sendable () -> Date
    /// Non-interactive timeout (Settings range 10 to 120 s).
    public var timeout: Duration

    private var cache: [String: Entry] = [:]
    private var inflight: [String: (id: UUID, task: Task<ExecCredential, Error>)] = [:]
    /// A failed run: not repeated within ``reRunInterval`` (a refresh that keeps failing must not spawn a plugin per request).
    private var failures: [String: (at: Date, error: ExecCredentialError)] = [:]
    private var lastRun: [String: Date] = [:]
    private var consumers: [String: Int] = [:]
    private var refreshTasks: [String: Task<Void, Never>] = [:]
    private var requests: [String: ExecRequest] = [:]
    /// Called with the key when a client-certificate credential rotated to a different certificate.
    private var rotationHandlers: [String: @Sendable () -> Void] = [:]
    /// Number of times a plugin was started (tests and the perf harness).
    public private(set) var runCount = 0

    public static let reRunInterval: TimeInterval = 10

    public init(locator: @escaping @Sendable () -> ExecutableLocator, environment: @escaping @Sendable () -> EnvironmentBuilder,
                runner: any ExecPluginRunning = SubprocessPluginRunner(), limiter: ExecConcurrencyLimiter = .shared,
                activity: any ActivityLogging = NoopActivityLog(), gate: DevSafetyPolicy = .current,
                timeout: Duration = .seconds(30), now: @escaping @Sendable () -> Date = { Date() }) {
        self.locator = locator
        self.environment = environment
        self.runner = runner
        self.limiter = limiter
        self.activity = activity
        self.gate = gate
        self.timeout = timeout
        self.now = now
    }

    // MARK: Credentials

    func credential(for request: ExecRequest) async throws -> ExecCredential {
        let key = request.key
        requests[key] = request
        if let entry = cache[key], !needsRefresh(entry) { return entry.credential }
        if let flight = inflight[key] { return try await flight.task.value }
        if request.spec.interactiveMode == "Always" { throw ExecCredentialError.signInRequired(command: request.spec.command) }
        // Back off after a failure: reuse a still-valid credential, or repeat the error, until the interval has passed.
        if let failure = failures[key], now().timeIntervalSince(failure.at) < Self.reRunInterval {
            if let entry = cache[key], let expiry = entry.credential.expirationTimestamp, now() < expiry { return entry.credential }
            throw failure.error
        }
        let id = UUID()
        let task = Task { try await self.fetch(request, key: key) }
        inflight[key] = (id, task)
        do {
            let value = try await task.value
            if inflight[key]?.id == id { inflight[key] = nil }
            failures[key] = nil
            return value
        } catch {
            if inflight[key]?.id == id { inflight[key] = nil }
            if let e = error as? ExecCredentialError, e != .cancelled { failures[key] = (now(), e) }
            // A refresh that fails must not break requests while the previous credential has not expired yet.
            if let entry = cache[key], let expiry = entry.credential.expirationTimestamp, now() < expiry { return entry.credential }
            throw error
        }
    }

    private func needsRefresh(_ entry: Entry) -> Bool {
        guard let at = entry.credential.refreshDate(obtainedAt: entry.obtainedAt) else { return false }
        return now() >= at
    }

    private func fetch(_ request: ExecRequest, key: String) async throws -> ExecCredential {
        try gate.requirePluginAllowed(cluster: request.cluster)
        guard let executable = locator().resolve(command: request.spec.command, baseDirectory: request.spec.baseDirectory) else {
            throw ExecCredentialError.pluginMissing(command: request.spec.command, installHint: request.spec.installHint,
                                                    suggestion: ExecPluginAdvice.installCommand(for: request.spec.command))
        }
        guard request.apiVersionIsSupported else { throw ExecCredentialError.unsupportedAPIVersion(request.apiVersion) }
        await limiter.acquire()
        defer { Task { await limiter.release() } }
        try Task.checkCancellation()
        let processSpec = makeProcessSpec(request, executable: executable, interactive: false)
        runCount += 1
        lastRun[key] = now()
        let started = ContinuousClock.now
        let result: ProcessResult
        do {
            result = try await runner.run(processSpec)
        } catch SubprocessError.timedOut {
            record(request, started: started, exit: "timed out")
            throw ExecCredentialError.timedOut(command: request.spec.command)
        } catch is CancellationError {
            throw ExecCredentialError.cancelled
        } catch {
            record(request, started: started, exit: "not started")
            throw ExecCredentialError.failed(command: request.spec.command, exitCode: nil, stderrTail: StderrRedactor.redact(error.localizedDescription))
        }
        record(request, started: started, exit: "exit \(result.exit.code.map(String.init) ?? "signal")")
        guard result.exit.code == 0 else {
            throw ExecCredentialError.failed(command: request.spec.command, exitCode: result.exit.code, stderrTail: StderrRedactor.tail(result.stderrTail))
        }
        let credential = try ExecCredential.parse(result.stdout, expectedAPIVersion: request.apiVersion, now: now())
        store(credential, key: key)
        return credential
    }

    /// Stores a credential obtained outside the broker (the Sign-in sheet) and wakes waiting requests.
    func accept(_ credential: ExecCredential, for request: ExecRequest) {
        requests[request.key] = request
        lastRun[request.key] = now()
        failures[request.key] = nil
        store(credential, key: request.key)
    }

    private func store(_ credential: ExecCredential, key: String) {
        let previous = cache[key]?.credential
        cache[key] = Entry(credential: credential, obtainedAt: now())
        if let previous, previous.isClientCertificate, credential.isClientCertificate, previous.certificateMaterial != credential.certificateMaterial {
            // A new certificate needs a new TLS identity, hence a new client: the registry rebuilds it on this notification.
            rotationHandlers[key]?()
        }
        scheduleRefresh(key: key)
    }

    func makeProcessSpec(_ request: ExecRequest, executable: URL, interactive: Bool) -> ProcessSpec {
        var additions: [String: String] = [:]
        for e in request.spec.env { additions[e.name] = e.value }
        additions["KUBERNETES_EXEC_INFO"] = request.execInfo(interactive: interactive)
        let env = environment().build(profile: .forPlugin(command: request.spec.command), additions: additions)
        let dir = request.spec.baseDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        return ProcessSpec(executable: executable, arguments: request.spec.args, environment: env, currentDirectory: dir,
                           timeout: interactive ? .seconds(300) : timeout, stdoutLimit: ExecCredential.maxOutput + 1, stderrLimit: 64 << 10, qos: .userInitiated)
    }

    /// The process the Sign-in sheet runs on a pseudo-terminal.
    func interactiveSpec(for request: ExecRequest) throws -> ProcessSpec {
        try gate.requirePluginAllowed(cluster: request.cluster)
        guard let executable = locator().resolve(command: request.spec.command, baseDirectory: request.spec.baseDirectory) else {
            throw ExecCredentialError.pluginMissing(command: request.spec.command, installHint: request.spec.installHint,
                                                    suggestion: ExecPluginAdvice.installCommand(for: request.spec.command))
        }
        return makeProcessSpec(request, executable: executable, interactive: true)
    }

    private func record(_ request: ExecRequest, started: ContinuousClock.Instant, exit: String) {
        let d = started.duration(to: .now)
        let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        let name = (request.spec.command as NSString).lastPathComponent
        activity.record(ActivityEntry(verb: "plugin", object: name, result: "plugin ran: \(name), \(String(format: "%.1f", seconds)) s, \(exit)"))
    }

    // MARK: Invalidation

    /// Drops the credential after a 401. At most one re-run per 10 s per key: an invalidation right after a run is ignored.
    func invalidate(key: String) {
        if let last = lastRun[key], now().timeIntervalSince(last) < Self.reRunInterval { return }
        cache[key] = nil
        refreshTasks[key]?.cancel()
        refreshTasks[key] = nil
    }

    /// Forgets every credential obtained for a kubeconfig file (its contexts changed).
    public func forget(kubeconfigPath: String) {
        for (key, request) in requests where request.kubeconfigPath == kubeconfigPath { forget(key: key) }
    }

    /// Forgets every credential of a key (cluster removed or its kubeconfig stanza changed).
    public func forget(key: String) {
        cache[key] = nil
        inflight[key]?.task.cancel(); inflight[key] = nil
        failures[key] = nil
        refreshTasks[key]?.cancel(); refreshTasks[key] = nil
        lastRun[key] = nil
    }

    // MARK: Consumers and refresh

    func addConsumer(key: String, request: ExecRequest) {
        requests[key] = request
        consumers[key, default: 0] += 1
        if cache[key] != nil { scheduleRefresh(key: key) }
    }

    func removeConsumer(key: String) {
        let n = max(0, (consumers[key] ?? 0) - 1)
        consumers[key] = n == 0 ? nil : n
        if n == 0 { refreshTasks[key]?.cancel(); refreshTasks[key] = nil }
    }

    /// Keys that currently have a scheduled background refresh (tests and the perf harness).
    public var scheduledRefreshKeys: [String] { Array(refreshTasks.keys).sorted() }

    private func scheduleRefresh(key: String) {
        refreshTasks[key]?.cancel(); refreshTasks[key] = nil
        guard (consumers[key] ?? 0) > 0, let entry = cache[key], let at = entry.credential.refreshDate(obtainedAt: entry.obtainedAt) else { return }
        let delay = max(1, at.timeIntervalSince(now()))
        refreshTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(max(1, delay * 0.05)), clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.refreshInBackground(key: key)
        }
    }

    private func refreshInBackground(key: String) async {
        refreshTasks[key] = nil
        guard (consumers[key] ?? 0) > 0, let request = requests[key] else { return }
        // Mark the entry due; the old credential stays usable until the new one arrives (or its own expiry).
        if let entry = cache[key] { cache[key] = Entry(credential: entry.credential, obtainedAt: .distantPast) }
        _ = try? await credential(for: request)
    }

    /// One handler per key: the newest client of a cluster replaces the previous one.
    func onRotation(key: String, _ handler: @escaping @Sendable () -> Void) { rotationHandlers[key] = handler }
}

extension ExecRequest {
    var apiVersionIsSupported: Bool {
        apiVersion == "client.authentication.k8s.io/v1" || apiVersion == "client.authentication.k8s.io/v1beta1"
    }
}

extension DevSafetyPolicy {
    /// While the gate is active a plugin runs only for a cluster whose server host is allowed.
    func requirePluginAllowed(cluster: ExecClusterInfo?) throws {
        guard isActive else { return }
        guard let server = cluster?.server, let url = URL(string: server), isAllowed(server: url) else {
            throw ExecCredentialError.developmentBlocked("Blocked in development builds: credential plugins run only for test clusters.")
        }
    }
}

/// One provider per (cluster, exec spec). Plugs into `LiveKubeClient` as `.dynamic(provider)`.
public final class ExecCredentialProvider: BearerTokenProviding, Sendable {
    private let broker: ExecCredentialBroker
    let request: ExecRequest
    public let key: String
    private let used = Mutex(false)

    public init(spec: KubeconfigExecSpec, cluster: ExecClusterInfo?, kubeconfigPath: String, broker: ExecCredentialBroker) {
        self.broker = broker
        self.request = ExecRequest(spec: spec, cluster: cluster, kubeconfigPath: kubeconfigPath)
        self.key = request.key
    }

    public func authorization() async throws -> String? {
        try await broker.credential(for: request).token
    }

    public func clientCertificate() async throws -> ClientCertificateMaterial? {
        try await broker.credential(for: request).certificateMaterial
    }

    public func invalidate() async { await broker.invalidate(key: key) }

    /// Marks this cluster as having a consumer (visible, open in a pane, pinned on the Rail or watched): only then may a background
    /// refresh task exist. Balanced by ``endUse()``.
    public func beginUse() async {
        let first = used.withLock { u -> Bool in defer { u = true }; return !u }
        if first { await broker.addConsumer(key: key, request: request) }
    }

    public func endUse() async {
        let was = used.withLock { u -> Bool in defer { u = false }; return u }
        if was { await broker.removeConsumer(key: key) }
    }

    /// Runs `handler` when a refresh produced a different client certificate.
    public func onCertificateRotation(_ handler: @escaping @Sendable () -> Void) async {
        await broker.onRotation(key: key, handler)
    }

    // MARK: Interactive sign-in (the sheet owns the pseudo-terminal)

    /// The process to run in the Sign-in sheet's PTY: `PTYProcess(spec:size:stdoutPipe: true)`.
    public func interactiveSpec() async throws -> ProcessSpec { try await broker.interactiveSpec(for: request) }

    /// Validates the plugin's stdout from the Sign-in sheet and caches the credential, so waiting requests resume.
    public func completeSignIn(stdout: Data) async throws {
        let credential = try ExecCredential.parse(stdout, expectedAPIVersion: request.apiVersion)
        await broker.accept(credential, for: request)
    }

    /// The program and arguments of a provider login command, from the stanza (`aws sso login --profile p`, `gcloud auth login`,
    /// `az login`). nil when the plugin has no known login command.
    public func providerLoginCommand() -> (program: String, arguments: [String])? {
        let name = (request.spec.command as NSString).lastPathComponent
        switch name {
        case "aws", "aws-iam-authenticator":
            var profile: String?
            for (i, a) in request.spec.args.enumerated() {
                if a == "--profile", request.spec.args.indices.contains(i + 1) { profile = request.spec.args[i + 1] }
                if a.hasPrefix("--profile=") { profile = String(a.dropFirst("--profile=".count)) }
            }
            profile = profile ?? request.spec.env.first { $0.name == "AWS_PROFILE" }?.value
            return ("aws", ["sso", "login"] + (profile.map { ["--profile", $0] } ?? []))
        case "gke-gcloud-auth-plugin", "gcloud": return ("gcloud", ["auth", "login"])
        case "kubelogin": return ("az", ["login"])
        default: return nil
        }
    }
}
#endif
