#if os(macOS)
import Foundation
import WheelhouseKit

/// What can go wrong running trivy, in terms the Survey UI can show.
public enum TrivyError: Error, Equatable, Sendable, LocalizedError {
    /// The registry refused the pull ("Sign in with your registry CLI").
    case unauthorized(registry: String)
    case databaseUnavailable(String)
    case failed(code: Int32?, message: String)
    case unreadableOutput
    case invalidImage(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let registry): "Not signed in to \(registry). Sign in with your registry CLI, then scan again."
        case .databaseUnavailable(let why): "The vulnerability database could not be downloaded. \(why) A mirror can be set in Settings."
        case .failed(_, let message): "trivy failed: \(message)"
        case .unreadableOutput: "trivy printed output that could not be read."
        case .invalidImage(let image): "\"\(image)\" is not a valid image reference."
        }
    }
}

/// Settings of a trivy run that do not change per image.
public struct TrivyOptions: Sendable, Equatable {
    public var cacheDirectory: URL
    /// `--db-repository` and `--java-db-repository`: a mirror for restricted networks.
    public var dbRepository: String?
    public var javaDBRepository: String?
    /// `arm64` or `amd64`: the default when a queue item names none.
    public var architecture: String

    public init(cacheDirectory: URL, dbRepository: String? = nil, javaDBRepository: String? = nil, architecture: String = "amd64") {
        self.cacheDirectory = cacheDirectory
        self.dbRepository = dbRepository
        self.javaDBRepository = javaDBRepository
        self.architecture = architecture
    }
}

/// The `trivy` adapter (ARCHITECTURE-MAC §6.1). The argv is built here and nowhere else; golden tests pin it. Runs through
/// ``Subprocess``: no shell, an explicit environment, one image at a time.
public struct TrivyCLI: Sendable {
    public var executable: URL
    public var environment: EnvironmentBuilder
    /// Overall timeout of one image scan (trivy's own `--timeout` is 10 m; this one is longer so trivy reports its own timeout).
    public var scanTimeout: Duration
    public var databaseTimeout: Duration
    /// A large image can produce a big report.
    public var outputLimit: Int

    public init(executable: URL, environment: EnvironmentBuilder, scanTimeout: Duration = .seconds(11 * 60), databaseTimeout: Duration = .seconds(30 * 60),
                outputLimit: Int = 256 << 20) {
        self.executable = executable
        self.environment = environment
        self.scanTimeout = scanTimeout
        self.databaseTimeout = databaseTimeout
        self.outputLimit = outputLimit
    }

    // MARK: argv (golden-tested)

    public static func scanArguments(target: String, options: TrivyOptions) -> [String] {
        var args = ["image", "--format", "json", "--quiet", "--scanners", "vuln", "--skip-db-update", "--image-src", "remote",
                    "--cache-dir", options.cacheDirectory.path, "--timeout", "10m", "--parallel", "1", "--platform", "linux/\(options.architecture)"]
        if let r = options.dbRepository, !r.isEmpty { args += ["--db-repository", r] }
        if let r = options.javaDBRepository, !r.isEmpty { args += ["--java-db-repository", r] }
        args += ["--", target]
        return args
    }

    public static func downloadDBArguments(options: TrivyOptions, java: Bool = false) -> [String] {
        var args = ["image", java ? "--download-java-db-only" : "--download-db-only", "--quiet", "--cache-dir", options.cacheDirectory.path]
        if java {
            if let r = options.javaDBRepository, !r.isEmpty { args += ["--java-db-repository", r] }
        } else if let r = options.dbRepository, !r.isEmpty {
            args += ["--db-repository", r]
        }
        return args
    }

    // MARK: Environment

    /// The environment of a run. The Docker and cloud variables are the user's (credential helpers need `HOME`; ECR, GCR and ACR
    /// need the cluster's cloud variables), except while the development gate is on: then no real credentials are reachable, and
    /// `DOCKER_CONFIG` points at an empty folder unless the caller supplies a per-scan one.
    public func processEnvironment(dockerConfig: URL?, cloud: [String: String]) -> [String: String] {
        var env = environment.build(profile: .trivy)
        let isolated = environment.paths.isolated
        if !isolated {
            let docker = environment.build(profile: .docker)
            for key in ["DOCKER_CONFIG", "DOCKER_HOST"] { if let v = docker[key] { env[key] = v } }
            // Trivy's own cloud auth for ECR, GCR and ACR reads the user's AWS, Google and Azure variables (the scrubbed allowlists).
            for profile in [EnvironmentBuilder.ToolProfile.aws, .google, .azure] {
                let cloudEnv = environment.build(profile: profile)
                for (k, v) in cloudEnv where env[k] == nil && k != "KUBECACHEDIR" { env[k] = v }
            }
            for (k, v) in cloud { env[k] = v }
        }
        if let dockerConfig {
            env["DOCKER_CONFIG"] = dockerConfig.path
        } else if isolated {
            env["DOCKER_CONFIG"] = environment.paths.root.appending(path: "empty-docker-config", directoryHint: .isDirectory).path
        }
        if isolated {
            // A development build reaches no real credential: not the user's home (cloud CLIs, keychain helpers) and not the cloud
            // metadata service.
            env["HOME"] = environment.paths.root.appending(path: "trivy-home", directoryHint: .isDirectory).path
            env["AWS_EC2_METADATA_DISABLED"] = "true"
        }
        // The run's shape is ours: a TRIVY_* variable of the shell must not redirect the output or the scan.
        for key in ["TRIVY_OUTPUT", "TRIVY_SERVER", "TRIVY_FORMAT", "TRIVY_QUIET", "TRIVY_IMAGE_SRC", "TRIVY_PLATFORM"] { env.removeValue(forKey: key) }
        env["TRIVY_NO_PROGRESS"] = "true"
        env["TRIVY_DISABLE_TELEMETRY"] = "true"
        return env
    }

    func spec(arguments: [String], env: [String: String], timeout: Duration, qos: QualityOfService) -> ProcessSpec {
        ProcessSpec(executable: executable, arguments: arguments, environment: env, timeout: timeout, stdoutLimit: outputLimit, stderrLimit: 64 << 10, qos: qos)
    }

    public func scanSpec(image: ImageReference, options: TrivyOptions, trigger: ScanTrigger, dockerConfig: URL?, cloud: [String: String]) -> ProcessSpec {
        spec(arguments: Self.scanArguments(target: image.scanTarget, options: options), env: processEnvironment(dockerConfig: dockerConfig, cloud: cloud),
             timeout: scanTimeout, qos: ScanGate.qos(for: trigger))
    }

    // MARK: Operations

    public func version() async throws -> String {
        let r = try await Subprocess.run(spec(arguments: ["--version"], env: processEnvironment(dockerConfig: nil, cloud: [:]), timeout: .seconds(15), qos: .utility))
        guard r.exit.succeeded else { throw TrivyError.failed(code: r.exit.code, message: r.stderrString) }
        return r.stdoutString.split(separator: "\n").first.map(String.init) ?? ""
    }

    /// Scans one image. The caller owns `dockerConfig` (a per-scan folder it deletes afterwards).
    public func scan(_ image: ImageReference, options: TrivyOptions, trigger: ScanTrigger, dockerConfig: URL? = nil,
                     cloud: [String: String] = [:]) async throws -> TrivyImageReportParser.Parsed {
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Scanning an image with trivy")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let result = try await Subprocess.run(scanSpec(image: image, options: options, trigger: trigger, dockerConfig: dockerConfig, cloud: cloud))
        guard result.exit.succeeded else { throw Self.classify(stderr: result.stderrString, code: result.exit.code, registry: image.registry) }
        do { return try TrivyImageReportParser.parse(result.stdout) } catch { throw TrivyError.unreadableOutput }
    }

    /// `trivy image --download-db-only` (and the Java DB when asked).
    public func downloadDatabase(options: TrivyOptions, java: Bool = false, trigger: ScanTrigger) async throws {
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Downloading the vulnerability database")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let r = try await Subprocess.run(spec(arguments: Self.downloadDBArguments(options: options, java: java), env: processEnvironment(dockerConfig: nil, cloud: [:]),
                                              timeout: databaseTimeout, qos: ScanGate.qos(for: trigger)))
        guard r.exit.succeeded else { throw TrivyError.databaseUnavailable(Self.lastLine(r.stderrString)) }
    }

    /// Trivy's own DB metadata, read without a process.
    public static func databaseMetadata(cacheDirectory: URL) -> TrivyDBMetadata? {
        (try? Data(contentsOf: cacheDirectory.appending(path: "db/metadata.json"))).flatMap(TrivyDBMetadata.parse)
    }

    /// `~/Library/Caches/trivy` (the user's cache, shared so the DB is not downloaded twice), or the app's own while isolated.
    public static func defaultCacheDirectory(paths: AppPaths) -> URL {
        paths.isolated ? paths.caches.appending(path: "trivy", directoryHint: .isDirectory)
            : paths.home.appending(path: "Library/Caches/trivy", directoryHint: .isDirectory)
    }

    static func classify(stderr: String, code: Int32?, registry: String) -> TrivyError {
        let lower = stderr.lowercased()
        if lower.contains("unauthorized") || lower.contains("authentication required") || lower.contains("denied: requested access")
            || lower.range(of: #"\b401\b"#, options: .regularExpression) != nil || lower.contains("403 forbidden") {
            return .unauthorized(registry: registry)
        }
        if lower.contains("--skip-db-update cannot be specified on the first run") || lower.contains("failed to download vulnerability db")
            || lower.contains("db error") || lower.contains("no such file or directory") && lower.contains("/db/") {
            return .databaseUnavailable(lastLine(stderr))
        }
        return .failed(code: code, message: lastLine(stderr))
    }

    static func lastLine(_ text: String) -> String {
        String(text.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "").prefix(400).description
    }
}
#endif
