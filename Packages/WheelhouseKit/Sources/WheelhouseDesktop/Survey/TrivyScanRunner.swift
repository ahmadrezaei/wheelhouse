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
        guard let dbVersion = metadata?.version else { throw TrivyError.databaseUnavailable("trivy left no database metadata.") }
        let key = ref.digest ?? ref.scanTarget
        if let cached = try await store.scan(id: key), DBUpdatePolicy.canReuse(cached, dbVersion: dbVersion, now: now()) { return cached }

        var lastError: Error = TrivyError.unauthorized(registry: ref.registry)
        for cluster in item.clusters.isEmpty ? [""] : item.clusters {
            try Task.checkCancellation()
            do {
                let parsed = try await scanOnce(ref, cluster: cluster, trigger: trigger, architecture: item.architecture)
                let result = ImageScanResult(image: ref.scanTarget, digest: ref.digest, isMutable: ref.isMutable, dbVersion: dbVersion, scannedAt: now(),
                                             vulnerabilities: parsed.vulnerabilities)
                try await store.save(result)
                return result
            } catch let error as TrivyError {
                guard case .unauthorized = error else { throw error }
                lastError = error
            }
        }
        throw lastError
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
