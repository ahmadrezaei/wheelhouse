#if os(macOS)
import Foundation
import WheelhouseKit

/// Why a `flux diff` did not produce a diff.
public enum FluxDiffError: Error, Equatable, Sendable, LocalizedError {
    /// No `flux` executable was found (the user's own CLI; Wheelhouse does not ship it).
    case notInstalled
    /// The mapped folder is gone or is not a folder.
    case folderMissing(String)
    /// A name that could be read as an option is refused.
    case invalidName(String)
    case timedOut(Int)
    case outputTooLarge
    case failed(code: Int32?, message: String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "The flux CLI is not installed. Install it (for example with Homebrew) and try again."
        case .folderMissing(let path): "The mapped folder no longer exists: \(path)"
        case .invalidName(let name): "\"\(name)\" cannot be used as a Kustomization name or namespace."
        case .outputTooLarge: "flux diff printed more than 8 MB; narrow the folder and try again."
        case .timedOut(let seconds): "flux diff did not finish within \(seconds) s."
        case .failed(_, let message): "flux diff failed: \(message)"
        }
    }
}

/// What a finished `flux diff` found.
public struct FluxDiffOutput: Sendable, Equatable {
    /// The diff text; empty when the folder matches the cluster.
    public var text: String
    /// Decided by flux's exit status (0 = same, 1 with a diff = differs), never by whether stdout has text.
    public var hasChanges: Bool
    public init(text: String, hasChanges: Bool) {
        self.text = text
        self.hasChanges = hasChanges
    }
}

/// The `flux` adapter (ARCHITECTURE-MAC section 7, "Flux diff"). The argv is built here and nowhere else. Flux reaches the cluster only
/// through the Gangway session file: the shell's `KUBECONFIG` is never passed (`EnvironmentBuilder` drops it).
public struct FluxCLI: Sendable {
    /// The quit group of every flux child.
    public static let quitGroup = "flux"
    public var executable: URL
    public var environment: EnvironmentBuilder

    public init(executable: URL, environment: EnvironmentBuilder) {
        self.executable = executable
        self.environment = environment
    }

    /// The user's `flux`, or nil when there is none.
    public static func locate(_ locator: ExecutableLocator, environment: EnvironmentBuilder) -> FluxCLI? {
        locator.find("flux").map { FluxCLI(executable: $0, environment: environment) }
    }

    /// `flux diff kustomization <name> --path <folder> --namespace <ns> --progress-bar=false`. Compares the folder with what the cluster has; changes nothing.
    public func diffArguments(name: String, namespace: String, folder: URL) throws -> [String] {
        for value in [name, namespace] where value.isEmpty || value.hasPrefix("-") { throw FluxDiffError.invalidName(value) }
        return ["diff", "kustomization", name, "--path", folder.path, "--namespace", namespace, "--progress-bar=false"]
    }

    /// `kubeconfig` is the Gangway session file.
    public func spec(arguments: [String], kubeconfig: URL, timeout: Duration) -> ProcessSpec {
        ProcessSpec(executable: executable, arguments: arguments, environment: environment.build(profile: .none, additions: ["KUBECONFIG": kubeconfig.path]),
                    timeout: timeout, stdoutLimit: 8 << 20, quitGroup: Self.quitGroup)
    }
}

/// Runs `flux diff` under a dry-run-only Gangway session: reads, reviews and server dry runs pass, any change is refused (never held).
public struct FluxDiffRunner: Sendable {
    public let cli: FluxCLI
    public let gangway: GangwayService
    public var timeout: Duration

    public init(cli: FluxCLI, gangway: GangwayService, timeout: Duration = .seconds(120)) {
        self.cli = cli
        self.gangway = gangway
        self.timeout = timeout
    }

    public func diff(kustomization name: String, namespace: String, folder: URL, cluster: ClusterID) async throws -> FluxDiffOutput {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw FluxDiffError.folderMissing(folder.path) }
        let args = try cli.diffArguments(name: name, namespace: namespace, folder: folder)
        let handle = try await gangway.openSession(clusterID: cluster, origin: .tides, scope: .dryRunOnly, namespace: namespace)
        defer { gangway.closeSession(handle, reason: "flux diff finished") }
        let result: ProcessResult
        do {
            result = try await Subprocess.run(cli.spec(arguments: args, kubeconfig: handle.kubeconfig, timeout: timeout))
        } catch SubprocessError.timedOut {
            throw FluxDiffError.timedOut(Int(timeout.components.seconds))
        } catch SubprocessError.outputTooLarge {
            throw FluxDiffError.outputTooLarge
        } catch SubprocessError.launchFailed(let why) {
            throw FluxDiffError.failed(code: nil, message: why)
        }
        return try Self.interpret(result)
    }

    /// flux exits 0 when nothing differs and 1 when it printed a diff; an exit 1 without any diff on stdout, or any other status, is a failure.
    static func interpret(_ result: ProcessResult) throws -> FluxDiffOutput {
        let text = result.stdoutString
        let printed = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if result.exit.succeeded { return FluxDiffOutput(text: "", hasChanges: false) }
        if result.exitCode == 1, printed { return FluxDiffOutput(text: text, hasChanges: true) }
        let err = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        throw FluxDiffError.failed(code: result.exitCode, message: err.isEmpty ? "exit code \(result.exitCode.map(String.init) ?? "none")" : err)
    }
}

/// The local folder mapped to each Kustomization, kept on this Mac in preferences. A path only: no secrets, nothing synced.
public final class FluxFolderMappings: @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ cluster: ClusterID, _ namespace: String, _ name: String) -> String { "tides.fluxFolder.\(cluster)/\(namespace)/\(name)" }

    public func folder(cluster: ClusterID, namespace: String, name: String) -> URL? {
        defaults.string(forKey: key(cluster, namespace, name)).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public func set(_ folder: URL?, cluster: ClusterID, namespace: String, name: String) {
        let k = key(cluster, namespace, name)
        if let folder { defaults.set(folder.standardizedFileURL.path, forKey: k) } else { defaults.removeObject(forKey: k) }
    }
}
#endif
