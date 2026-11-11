#if os(macOS)
import Foundation
import WheelhouseKit

/// A helm version (`v3.11.2`, `4.0.0`, `v3.14.0-rc.1`).
public struct HelmVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public init(_ major: Int, _ minor: Int, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Reads the output of `helm version --template '{{.Version}}'` (a leading `v` and a pre-release or build suffix are ignored).
    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let core = trimmed.drop { $0 == "v" }.prefix { $0 != "-" && $0 != "+" }
        let parts = core.split(separator: ".").map { Int($0) }
        guard parts.count >= 2, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.init(parts[0] ?? 0, parts[1] ?? 0, parts.count > 2 ? parts[2] ?? 0 : 0)
    }

    public static func < (a: HelmVersion, b: HelmVersion) -> Bool { (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
    public var description: String { "\(major).\(minor).\(patch)" }
    public var isHelm4: Bool { major >= 4 }
}

/// How an upgrade treats the values the release already has.
public enum HelmValueStrategy: Sendable, Equatable {
    /// Only the values file counts (`--reset-values`). The editor starts from the release's own values, so nothing is lost.
    case reset
    /// The chart's new defaults, then the release's values, then the file (`--reset-then-reuse-values`, Helm 3.14 and newer).
    case resetThenReuse
}

/// What to run (ARCHITECTURE-MAC section 5.2).
public enum HelmOperation: Sendable, Equatable {
    case install(release: String, chart: String, version: String?, namespace: String, createNamespace: Bool)
    case upgrade(release: String, chart: String, version: String?, namespace: String, strategy: HelmValueStrategy)
    case rollback(release: String, namespace: String, revision: Int)
    case uninstall(release: String, namespace: String, keepHistory: Bool)

    public var release: String {
        switch self {
        case .install(let r, _, _, _, _), .upgrade(let r, _, _, _, _), .rollback(let r, _, _), .uninstall(let r, _, _): r
        }
    }
    public var namespace: String {
        switch self {
        case .install(_, _, _, let n, _), .upgrade(_, _, _, let n, _), .rollback(_, let n, _), .uninstall(_, let n, _): n
        }
    }
    /// `install` or `upgrade` run through helm's own render and take a values file.
    public var rendersWithHelm: Bool {
        switch self {
        case .install, .upgrade: true
        case .rollback, .uninstall: false
        }
    }
    public var verb: String {
        switch self {
        case .install: "install"
        case .upgrade: "upgrade"
        case .rollback: "rollback"
        case .uninstall: "uninstall"
        }
    }
}

/// Options of the apply step.
public struct HelmApplyOptions: Sendable, Equatable {
    public var wait: Bool
    public var timeout: Duration
    /// "Roll back automatically on failure": `--rollback-on-failure` on Helm 4, `--atomic` on Helm 3.
    public var rollbackOnFailure: Bool
    public var skipCRDs: Bool
    public init(wait: Bool = true, timeout: Duration = .seconds(300), rollbackOnFailure: Bool = false, skipCRDs: Bool = false) {
        self.wait = wait
        self.timeout = timeout
        self.rollbackOnFailure = rollbackOnFailure
        self.skipCRDs = skipCRDs
    }
}

public enum HelmCLIError: Error, Equatable, Sendable, LocalizedError {
    case unsupported(String)
    case unreadableVersion(String)
    case failed(code: Int32?, message: String)
    case unreadableOutput
    public var errorDescription: String? {
        switch self {
        case .unsupported(let why): why
        case .unreadableVersion(let text): "helm printed a version Wheelhouse does not understand: \(text)"
        case .failed(_, let message): "helm failed: \(message)"
        case .unreadableOutput: "helm printed output that could not be read."
        }
    }
}

/// The `helm` adapter. The argv is built here and nowhere else (golden-tested for every operation and version). It refuses an option the
/// detected helm lacks. Values travel only through a values file: never `--set`, never argv.
public struct HelmCLI: Sendable {
    /// The quit group of every helm child (``Subprocess/terminateAll(group:)`` at app quit).
    public static let quitGroup = "helm"
    public var executable: URL
    public var version: HelmVersion
    public var environment: EnvironmentBuilder

    public init(executable: URL, version: HelmVersion, environment: EnvironmentBuilder) {
        self.executable = executable
        self.version = version
        self.environment = environment
    }

    /// Asks the binary for its version. No cluster, no Gangway.
    public static func detect(executable: URL, environment: EnvironmentBuilder) async throws -> HelmCLI {
        let spec = ProcessSpec(executable: executable, arguments: ["version", "--template", "{{.Version}}"],
                               environment: environment.build(profile: .helm), timeout: .seconds(20), stdoutLimit: 4096)
        let result = try await Subprocess.run(spec)
        guard result.exit.succeeded else { throw HelmCLIError.failed(code: result.exitCode, message: result.stderrString) }
        guard let version = HelmVersion(parsing: result.stdoutString) else { throw HelmCLIError.unreadableVersion(result.stdoutString) }
        return HelmCLI(executable: executable, version: version, environment: environment)
    }

    // MARK: Capabilities

    /// `--dry-run=server` needs Helm 3.13 or newer (Helm 3.11 can only render on the client).
    public var supportsServerDryRun: Bool { version >= HelmVersion(3, 13) }
    public var supportsResetThenReuse: Bool { version >= HelmVersion(3, 14) }

    // MARK: argv

    /// The render step of an install or upgrade: a dry run printed as JSON. Runs under a dry-run-only session.
    public func renderArguments(_ op: HelmOperation, valuesFile: URL?) throws -> [String] {
        var args = try chartArguments(op, valuesFile: valuesFile)
        args.append(supportsServerDryRun ? "--dry-run=server" : "--dry-run")
        args += ["--output", "json"]
        return args
    }

    /// The real run. `valuesFile` is used by install and upgrade only.
    public func applyArguments(_ op: HelmOperation, valuesFile: URL?, options: HelmApplyOptions) throws -> [String] {
        var args: [String]
        let seconds = "\(options.timeout.components.seconds)s"
        switch op {
        case .install, .upgrade:
            args = try chartArguments(op, valuesFile: valuesFile)
            if options.skipCRDs { args.append("--skip-crds") }
            if options.rollbackOnFailure { args.append(version.isHelm4 ? "--rollback-on-failure" : "--atomic") }
            if options.wait { args.append("--wait") }
            args += ["--timeout", seconds]
        case .rollback(let release, let namespace, let revision):
            args = ["rollback", release, String(revision), "--namespace", namespace]
            if options.wait { args.append("--wait") }
            args += ["--timeout", seconds]
        case .uninstall(let release, let namespace, let keepHistory):
            args = ["uninstall", release, "--namespace", namespace]
            if keepHistory { args.append("--keep-history") }
            if options.wait { args.append("--wait") }
            args += ["--timeout", seconds]
        }
        return args
    }

    /// `helm show crds`: the objects of the chart's `crds/` folder (no cluster).
    public func showCRDsArguments(chart: String, version chartVersion: String?) -> [String] {
        var args = ["show", "crds", chart]
        if let chartVersion, !chartVersion.isEmpty { args += ["--version", chartVersion] }
        return args
    }

    private func chartArguments(_ op: HelmOperation, valuesFile: URL?) throws -> [String] {
        var args: [String]
        let refs: [String]
        switch op {
        case .install(let r, let c, _, _, _), .upgrade(let r, let c, _, _, _): refs = [r, c]
        case .rollback, .uninstall: refs = []
        }
        if refs.contains(where: { $0.hasPrefix("-") || $0.isEmpty }) { throw HelmCLIError.unsupported("A release name or chart that starts with - is refused.") }
        switch op {
        case .install(let release, let chart, let chartVersion, let namespace, let create):
            args = ["install", release, chart, "--namespace", namespace]
            if create { args.append("--create-namespace") }
            if let chartVersion, !chartVersion.isEmpty { args += ["--version", chartVersion] }
        case .upgrade(let release, let chart, let chartVersion, let namespace, let strategy):
            args = ["upgrade", release, chart, "--namespace", namespace]
            if let chartVersion, !chartVersion.isEmpty { args += ["--version", chartVersion] }
            switch strategy {
            case .reset: args.append("--reset-values")
            case .resetThenReuse:
                guard supportsResetThenReuse else { throw HelmCLIError.unsupported("Keeping the release's values needs helm 3.14 or newer; this helm is \(version).") }
                args.append("--reset-then-reuse-values")
            }
        case .rollback, .uninstall:
            throw HelmCLIError.unsupported("A \(op.verb) has no values and is reviewed natively.")
        }
        if let valuesFile { args += ["--values", valuesFile.path] }
        return args
    }

    // MARK: Process

    /// `kubeconfig` is the Gangway session file: helm reaches the cluster only through it.
    public func spec(arguments: [String], kubeconfig: URL?, timeout: Duration, newSession: Bool = false,
                     spawnGate: (@Sendable (pid_t) -> Bool)? = nil) -> ProcessSpec {
        // A run without a session (repo, pull, show, version) never reads a kubeconfig at all.
        let additions = ["KUBECONFIG": kubeconfig?.path ?? "/dev/null"]
        return ProcessSpec(executable: executable, arguments: arguments, environment: environment.build(profile: .helm, additions: additions),
                           timeout: timeout, stdoutLimit: 64 << 20, quitGroup: Self.quitGroup, newSession: newSession, spawnGate: spawnGate)
    }
}
#endif
