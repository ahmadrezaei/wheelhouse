#if os(macOS)
import Foundation
import WheelhouseKit

public struct CLIOutput: Sendable, Equatable {
    public var exitCode: Int32?
    public var stdout: Data
    public var stderr: String
    public var succeeded: Bool { exitCode == 0 }
    public init(exitCode: Int32?, stdout: Data, stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum CLIError: Error, Equatable, Sendable, LocalizedError {
    case notInstalled(String)
    /// Cloud CLIs do not run in development builds (they talk to real accounts).
    case disabled(String)
    case failed(exitCode: Int32?, stderr: String)
    case invalidOutput(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let tool): "\(tool) was not found."
        case .disabled(let why): why
        case .failed(let code, let stderr): "The command failed (exit \(code.map(String.init) ?? "signal")). \(stderr.suffix(300))"
        case .invalidOutput(let why): "The command printed something unexpected: \(why)"
        case .timedOut: "The command timed out."
        }
    }
}

/// Runs a cloud CLI and returns its output. The real one is ``SubprocessCLIRunner``; tests use recorded output.
public protocol CLIRunner: Sendable {
    func run(_ provider: CloudProvider, _ arguments: [String], environment: [String: String]) async throws -> CLIOutput
}

public extension CLIRunner {
    /// stdout of a successful run, or ``CLIError/failed(exitCode:stderr:)``.
    func output(_ provider: CloudProvider, _ arguments: [String], environment: [String: String] = [:]) async throws -> Data {
        let out = try await run(provider, arguments, environment: environment)
        guard out.succeeded else { throw CLIError.failed(exitCode: out.exitCode, stderr: out.stderr) }
        return out.stdout
    }

    func json(_ provider: CloudProvider, _ arguments: [String], environment: [String: String] = [:]) async throws -> Any {
        let data = try await output(provider, arguments, environment: environment)
        do { return try JSONSerialization.jsonObject(with: data) } catch { throw CLIError.invalidOutput("not JSON") }
    }
}

// MARK: - Failure classification

public enum CLIFailure: Equatable, Sendable {
    case signedOut
    case accessDenied(action: String?)
    case other(String)

    /// Reads the CLI's own wording.
    public static func classify(_ error: Error) -> CLIFailure {
        guard case CLIError.failed(_, let stderr) = error else { return .other(error.localizedDescription) }
        let lower = stderr.lowercased()
        let signedOutMarkers = ["sso session", "error loading sso token", "token has expired", "has expired", "sso login", "unable to locate credentials", "expiredtoken", "refresh token has expired",
                                "gcloud auth login", "reauthentication", "do not currently have an active account", "az login",
                                "aadsts", "interactive authentication is needed", "unable to refresh"]
        if signedOutMarkers.contains(where: lower.contains) { return .signedOut }
        let deniedMarkers = ["accessdenied", "not authorized", "permission_denied", "does not have permission", "authorizationfailed", "forbidden"]
        if deniedMarkers.contains(where: lower.contains) {
            // The IAM action named by the message (`eks:ListClusters`, `container.clusters.list`).
            let action = stderr.split(whereSeparator: { " \t\n\"'(),".contains($0) }).map(String.init)
                .first { $0.range(of: #"^[a-z0-9-]+:[A-Za-z*]+$"#, options: .regularExpression) != nil || $0.hasPrefix("container.") }
            return .accessDenied(action: action)
        }
        return .other(String(stderr.suffix(200)).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func issue(scope: String) -> LandfallIssue {
        switch self {
        case .signedOut: .signInRequired(scope: scope)
        case .accessDenied(let action): .accessDenied(scope: scope, action: action)
        case .other(let message): .failed(scope: scope, message: message)
        }
    }
}

// MARK: - Concurrency

/// At most `limit` holders at once. Waiters leave the queue when their task is cancelled.
public actor ConcurrencyLimiter {
    public let limit: Int
    private var running = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    public private(set) var peak = 0

    public init(limit: Int) { self.limit = max(1, limit) }

    public func acquire() async throws {
        try Task.checkCancellation()
        if running < limit { running += 1; peak = max(peak, running); return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                waiters.append((id, c))
                if Task.isCancelled { cancel(id) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).continuation.resume(throwing: CancellationError())
    }

    public func release() {
        if waiters.isEmpty { running -= 1; return }
        // The slot is handed straight to the next waiter.
        waiters.removeFirst().continuation.resume()
    }

    public func withSlot<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let value = try await body()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }
}

// MARK: - The real runner

/// Where a run is confined during tests: HOME and every cloud config directory point into `home`, and only an executable inside
/// `allowedExecutableDirectory` may start.
public struct CLIIsolation: Sendable {
    public var home: URL
    public var allowedExecutableDirectory: URL
    public init(home: URL, allowedExecutableDirectory: URL) {
        self.home = home
        self.allowedExecutableDirectory = allowedExecutableDirectory
    }
}

/// Runs `aws`, `gcloud` and `az` through ``Subprocess`` (ARCHITECTURE-MAC §8.1, §13.2).
///
/// - While the gate is active nothing is located or started: ``makeSpec(_:_:environment:qos:)`` throws first.
/// - Without `isolation` the PROCESS gate (`DevSafety.isActive`) must also be off, whatever policy was injected, so a test that builds an
///   open policy still cannot start a real CLI against the owner's accounts.
/// - With `isolation`, HOME and the config directories are inside a temporary folder and only that folder's executables run.
/// - One limiter serves every adapter: at most 6 processes at once, at utility QoS. A slot is held only while a process runs.
public final class SubprocessCLIRunner: CLIRunner {
    public typealias Spawn = @Sendable (ProcessSpec) async throws -> ProcessResult

    public static let maxParallel = 6

    private let gateProvider: @Sendable () -> DevSafetyPolicy
    private let processGateActive: @Sendable () -> Bool
    private let locator: @Sendable () async -> ExecutableLocator
    private let snapshot: @Sendable () async -> ShellSnapshot?
    private let paths: AppPaths
    private let isolation: CLIIsolation?
    private let limiter: ConcurrencyLimiter
    private let spawn: Spawn
    private let timeout: Duration

    public init(gateProvider: @escaping @Sendable () -> DevSafetyPolicy = { .current },
                processGateActive: @escaping @Sendable () -> Bool = { DevSafety.isActive },
                locator: @escaping @Sendable () async -> ExecutableLocator,
                snapshot: @escaping @Sendable () async -> ShellSnapshot?,
                paths: AppPaths = .current, isolation: CLIIsolation? = nil,
                limiter: ConcurrencyLimiter = ConcurrencyLimiter(limit: SubprocessCLIRunner.maxParallel),
                timeout: Duration = .seconds(60), spawn: @escaping Spawn = { try await Subprocess.run($0) }) {
        self.gateProvider = gateProvider
        self.processGateActive = processGateActive
        self.locator = locator
        self.snapshot = snapshot
        self.paths = paths
        self.isolation = isolation
        self.limiter = limiter
        self.timeout = timeout
        self.spawn = spawn
    }

    /// The spec for a run (also used by the Sign-in sheet for login commands). Throws before any lookup while the gate is active.
    public func makeSpec(_ provider: CloudProvider, _ arguments: [String], environment: [String: String], qos: QualityOfService = .utility) async throws -> ProcessSpec {
        let gate = gateProvider()
        guard gate.allowsCloudCLIs else { throw CLIError.disabled("Cloud CLIs are disabled in development builds.") }
        if isolation == nil, processGateActive() { throw CLIError.disabled("Cloud CLIs are disabled in development builds.") }

        guard let exe = await locator().find(provider.tool) else { throw CLIError.notInstalled(provider.tool) }
        let snap = isolation == nil ? await snapshot() : nil
        var extra: [String: String] = [
            "AWS_PAGER": "", "CLOUDSDK_CORE_DISABLE_PROMPTS": "1", "CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK": "1",
            "AZURE_CORE_NO_COLOR": "true", "AZURE_CORE_COLLECT_TELEMETRY": "false", "AZURE_CORE_ONLY_SHOW_ERRORS": "true",
        ]
        extra.merge(environment) { _, new in new }
        let home: URL
        if let isolation {
            let allowed = isolation.allowedExecutableDirectory.resolvingSymlinksInPath().standardizedFileURL.path
            let resolved = exe.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(allowed + "/") else { throw CLIError.disabled("\(provider.tool) is outside the isolated tools folder.") }
            home = isolation.home
            let h = isolation.home.path
            extra["HOME"] = h
            extra["AWS_CONFIG_FILE"] = h + "/.aws/config"
            extra["AWS_SHARED_CREDENTIALS_FILE"] = h + "/.aws/credentials"
            extra["CLOUDSDK_CONFIG"] = h + "/.config/gcloud"
            extra["AZURE_CONFIG_DIR"] = h + "/.azure"
            extra["PATH"] = isolation.allowedExecutableDirectory.path + ":/usr/bin:/bin"
        } else {
            home = DevSafetyPolicy.accountHome
        }
        let env = EnvironmentBuilder(snapshot: snap, paths: paths, home: home).build(profile: provider.toolProfile, additions: extra)
        return ProcessSpec(executable: exe, arguments: arguments, environment: env, currentDirectory: isolation?.home, timeout: timeout,
                           stdoutLimit: 16 << 20, stderrLimit: 16 << 10, qos: qos)
    }

    public func run(_ provider: CloudProvider, _ arguments: [String], environment: [String: String]) async throws -> CLIOutput {
        let spec = try await makeSpec(provider, arguments, environment: environment)
        let spawn = self.spawn
        do {
            let result = try await limiter.withSlot { try await spawn(spec) }
            return CLIOutput(exitCode: result.exit.code, stdout: result.stdout, stderr: result.stderrString)
        } catch SubprocessError.timedOut {
            throw CLIError.timedOut
        } catch SubprocessError.launchFailed {
            throw CLIError.notInstalled(provider.tool)
        }
    }
}
#endif
