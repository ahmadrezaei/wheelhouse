#if os(macOS)
import Foundation
import WheelhouseKit

/// The real ``ScanRunner``: reuses a stored result when the DB version is unchanged, refreshes the vulnerability DB at most once per
/// 24 h (only because a scan was requested), and scans with the credentials of each cluster that runs the image in turn: an
/// "unauthorized" tries the next cluster before the image is reported as needing a sign-in.
public struct TrivyScanRunner: ScanRunner {
    public var cli: TrivyCLI
    public var options: TrivyOptions
    public var store: SurveyStore
    public var paths: AppPaths
    /// The cloud environment of a cluster (its exec plugin's `AWS_PROFILE` and so on). Empty for none.
    public var cloudEnvironment: @Sendable (String) async -> [String: String]
    /// A minimal docker `config.json` for the image's registry from the cluster's imagePullSecrets, only when the cluster opted in.
    public var pullSecretConfig: @Sendable (String, ImageReference) async -> Data?
    public var now: @Sendable () -> Date

    public init(cli: TrivyCLI, options: TrivyOptions, store: SurveyStore, paths: AppPaths,
                cloudEnvironment: @escaping @Sendable (String) async -> [String: String] = { _ in [:] },
                pullSecretConfig: @escaping @Sendable (String, ImageReference) async -> Data? = { _, _ in nil },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.cli = cli
        self.options = options
        self.store = store
        self.paths = paths
        self.cloudEnvironment = cloudEnvironment
        self.pullSecretConfig = pullSecretConfig
        self.now = now
    }

    public func scan(_ item: ScanQueueItem, trigger: ScanTrigger) async throws -> ImageScanResult {
        guard let ref = ImageReference(item.image) else { throw TrivyError.invalidImage(item.image) }
        var metadata = TrivyCLI.databaseMetadata(cacheDirectory: options.cacheDirectory)
        if DBUpdatePolicy.needsDownload(metadata: metadata, now: now()) {
            try await cli.downloadDatabase(options: options, trigger: trigger)
            metadata = TrivyCLI.databaseMetadata(cacheDirectory: options.cacheDirectory)
        }
        guard let dbVersion = metadata?.cacheKey else { throw TrivyError.databaseUnavailable("trivy left no database metadata.") }
        let key = ref.digest ?? ref.scanTarget
        if var cached = try await store.scan(id: key), DBUpdatePolicy.canReuse(cached, dbVersion: dbVersion, now: now()) {
            let missing = item.clusters.filter { !cached.clusters.contains($0) }
            if !missing.isEmpty { cached.clusters += missing; try await store.save(cached) }
            return cached
        }

        var lastError: Error = TrivyError.unauthorized(registry: ref.registry)
        for cluster in item.clusters.isEmpty ? [""] : item.clusters {
            try Task.checkCancellation()
            do {
                let parsed = try await scanWithJavaFallback(ref, cluster: cluster, trigger: trigger, architecture: item.architecture)
                let result = ImageScanResult(image: ref.scanTarget, digest: ref.digest, isMutable: ref.isMutable, dbVersion: dbVersion, scannedAt: now(),
                                             vulnerabilities: parsed.vulnerabilities, clusters: item.clusters)
                try await store.save(result)
                return result
            } catch let error as TrivyError {
                guard case .unauthorized = error else { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    /// The Java DB is downloaded only when it is needed (an image with JARs) or already present and stale, under the same 24 h rule
    /// as the vulnerability DB, keyed on `<cache>/java-db/metadata.json`. A scan runs with `--skip-java-db-update`; when trivy says the
    /// Java DB is missing it is fetched once and the scan retried. A failure of THAT download is a database problem, never "the image
    /// registry refused you".
    private func scanWithJavaFallback(_ ref: ImageReference, cluster: String, trigger: ScanTrigger, architecture: String?) async throws -> TrivyImageReportParser.Parsed {
        if let java = TrivyCLI.javaDatabaseMetadata(cacheDirectory: options.cacheDirectory), DBUpdatePolicy.needsDownload(metadata: java, now: now()) {
            try await cli.downloadDatabase(options: options, java: true, trigger: trigger)
        }
        do {
            return try await scanOnce(ref, cluster: cluster, trigger: trigger, architecture: architecture)
        } catch TrivyError.javaDatabaseMissing {
            try await cli.downloadDatabase(options: options, java: true, trigger: trigger)
            return try await scanOnce(ref, cluster: cluster, trigger: trigger, architecture: architecture)
        }
    }

    private func scanOnce(_ ref: ImageReference, cluster: String, trigger: ScanTrigger, architecture: String?) async throws -> TrivyImageReportParser.Parsed {
        let cloud = await cloudEnvironment(cluster)
        let cli = self.cli
        var chosen = self.options
        if let architecture { chosen.architecture = architecture }
        let options = chosen
        if let config = await pullSecretConfig(cluster, ref) {
            return try await ScanDockerConfig.with(config: config, in: paths.sessions) { dir in
                try await cli.scan(ref, options: options, trigger: trigger, dockerConfig: dir, cloud: cloud)
            }
        }
        return try await cli.scan(ref, options: options, trigger: trigger, cloud: cloud)
    }
}

/// Watches the power source, Low Power Mode and the thermal state for the queue. IOKit's power notification and
/// `NotificationCenter` are event driven: no wakeups while nothing changes.
public final class SystemScanConditionsObserver: ScanConditionsObserver, @unchecked Sendable {
    private let power = PowerSourceMonitor()
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    public init() {}

    deinit { stop() }

    public static func current() -> ScanConditions {
        let p = ProcessInfo.processInfo
        return ScanConditions(onBattery: PowerSourceMonitor.onBattery, lowPowerMode: p.isLowPowerModeEnabled, thermalState: p.thermalState)
    }

    public func start(_ onChange: @escaping @Sendable () -> Void) {
        stop()
        power.start { _ in onChange() }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification]
        let new = names.map { center.addObserver(forName: $0, object: nil, queue: nil) { _ in onChange() } }
        lock.withLock { tokens = new }
    }

    public func stop() {
        power.stop()
        let old = lock.withLock { () -> [NSObjectProtocol] in defer { tokens = [] }; return tokens }
        old.forEach(NotificationCenter.default.removeObserver)
    }
}
#endif
