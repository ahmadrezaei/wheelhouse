import AppKit
import Foundation
import Observation
import WheelhouseDesktop
import WheelhouseKit

/// The Settings of local scanning (`survey.scan.*`).
enum SurveyScanSettings {
    static let onlyOnPower = "survey.scan.onlyOnPower"
    static let dbRepository = "survey.scan.dbRepository"
    static let javaDBRepository = "survey.scan.javaDBRepository"
    static let trivyPath = "survey.scan.trivyPath"
    static let eventPrefix = "survey.scan."

    static var isOnlyOnPower: Bool { UserDefaults.standard.object(forKey: onlyOnPower) as? Bool ?? true }
    static func string(_ key: String) -> String? { UserDefaults.standard.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 } }
}

/// Where trivy comes from, in the order of ARCHITECTURE-MAC §6.1: the path set in Settings, the user's `trivy` on PATH, then the
/// consented managed download.
enum ScannerSource: Equatable {
    case none
    case configured(URL)
    case onPath(URL)
    case managed(URL)

    var url: URL? {
        switch self {
        case .none: nil
        case .configured(let u), .onPath(let u), .managed(let u): u
        }
    }
    var title: String {
        switch self {
        case .none: "Not installed"
        case .configured(let u): "Your trivy (\(u.path))"
        case .onPath(let u): "Your trivy on PATH (\(u.path))"
        case .managed: "Wheelhouse-managed trivy"
        }
    }
}

/// What the scan runner needs about each cluster: its client (to read pull secrets when the user opted in) and the pull-secret
/// references seen on its pods.
private actor ScanClusterContext {
    var clients: [ClusterID: any KubeClientProtocol] = [:]
    var secrets: [ClusterID: [String: [PullSecretRef]]] = [:]
    let store: SurveyStore

    init(store: SurveyStore) { self.store = store }

    func set(clients: [ClusterID: any KubeClientProtocol], secrets: [ClusterID: [String: [PullSecretRef]]]) {
        // Merged, not replaced: images queued by an earlier request (or restored from a previous launch) keep their secrets.
        self.clients.merge(clients) { _, new in new }
        self.secrets.merge(secrets) { _, new in new }
    }

    /// The minimal docker config for `ref` from the cluster's imagePullSecrets, only when the cluster opted in.
    func pullSecretConfig(cluster: ClusterID, ref: ImageReference) async -> Data? {
        guard (try? await store.usesPullSecrets(clusterID: cluster)) == true, let client = clients[cluster] else { return nil }
        for s in secrets[cluster]?[ref.scanTarget] ?? [] {
            guard let raw = try? await client.getRaw(.secret, name: s.name, namespace: s.namespace),
                  raw["type"]?.stringValue == "kubernetes.io/dockerconfigjson",
                  let encoded = raw.value(at: "data")?[".dockerconfigjson"]?.stringValue, let data = Data(base64Encoded: encoded),
                  let config = DockerConfigBuilder.minimalConfig(fromDockerConfigJSON: data, registry: ref.registry) else { continue }
            return config
        }
        return nil
    }
}

/// App-wide state of local vulnerability scanning. Created on first use (a Vulnerabilities tab or its Settings), never at launch:
/// until then no database is opened and nothing observes the power source. With no scan queued it holds no timer, task or observer.
@MainActor @Observable
final class ScanCoordinator {
    static let shared = ScanCoordinator(hub: .shared)

    private(set) var progress = ScanProgress()
    private(set) var source: ScannerSource = .none
    private(set) var scans: [ImageScanResult] = []
    /// `scan id → workloads` per cluster, rebuilt by each scan request.
    private(set) var workloadsByImage: [ClusterID: [String: [TrivyOperator.WorkloadKey]]] = [:]
    private(set) var message: String?
    private(set) var isPreparing = false
    private(set) var pin: TrivyPin.State = TrivyPin.bundled

    @ObservationIgnored private(set) var store: SurveyStore?
    @ObservationIgnored private var queue: ScanQueue?
    @ObservationIgnored private var context: ScanClusterContext?
    @ObservationIgnored private let paths: AppPaths
    /// Test seams.
    @ObservationIgnored private let conditions: @Sendable () -> ScanConditions
    @ObservationIgnored private let managedDownloader: any TrivyDownloader
    @ObservationIgnored private var storeURL: URL
    @ObservationIgnored private var lastReloadedScanned = 0
    @ObservationIgnored private var preparing: Task<Void, Never>?
    @ObservationIgnored private var terminateToken: NSObjectProtocol?
    /// Receives the opened database so the accepted risks move into it.
    @ObservationIgnored private weak var hub: SurveyHub?

    init(paths: AppPaths = .current, conditions: @escaping @Sendable () -> ScanConditions = { SystemScanConditionsObserver.current() },
         managedDownloader: any TrivyDownloader = URLSessionTrivyDownloader(), pin: TrivyPin.State = TrivyPin.bundled, hub: SurveyHub? = nil) {
        self.hub = hub
        self.paths = paths
        self.conditions = conditions
        self.managedDownloader = managedDownloader
        self.pin = pin
        storeURL = paths.root.appending(path: "survey.sqlite")
    }

    var managed: ManagedTrivy { ManagedTrivy(paths: paths, pin: pin, downloader: managedDownloader) }

    /// Opens `survey.sqlite` (lazily), restores the queue (it never starts by itself) and sweeps per-scan docker folders a crash left.
    func prepare() async {
        if let preparing { await preparing.value; return }
        guard store == nil else { return }
        let task = Task { await self.openStore() }
        preparing = task
        await task.value
        preparing = nil
    }

    private func openStore() async {
        isPreparing = true
        defer { isPreparing = false }
        do {
            try? paths.prepare()
            ScanDockerConfig.sweepStale(in: paths.sessions)
            let opened = try SurveyStore(url: storeURL)
            store = opened
            context = ScanClusterContext(store: opened)
            try? await opened.prune(olderThan: DBUpdatePolicy.resultMaximumAge * 4)
            scans = (try? await opened.allScans()) ?? []
            // A quit while a pull-secret scan runs would leave its private folder behind: remove any at termination too.
            if terminateToken == nil {
                let sessions = paths.sessions
                terminateToken = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
                    ScanDockerConfig.sweepStale(in: sessions)
                }
            }
            await hub?.attach(store: opened)
            await resolveSource()
            await makeQueue()
            await queue?.restore()
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Source

    func resolveSource() async {
        let before = source
        await locateSource()
        // A new trivy (or none) means a new runner; a running queue is left alone until it ends.
        if source != before || queue == nil, progress.state != .running, store != nil { await makeQueue() }
    }

    private func locateSource() async {
        if let custom = SurveyScanSettings.string(SurveyScanSettings.trivyPath), FileManager.default.isExecutableFile(atPath: custom) {
            source = .configured(URL(fileURLWithPath: custom))
        } else {
            let snapshot = await MooringsController.shared?.shellEnvironment.current()
            if let found = ExecutableLocator(snapshot: snapshot, home: paths.home).find("trivy") {
                source = .onPath(found)
            } else if let exe = managed.verifiedExecutable() {
                source = .managed(exe)
            } else {
                source = .none
            }
        }
    }

    /// The user accepted the consent sheet: download, verify, install.
    func installManaged() async {
        do {
            _ = try await managed.install()
            message = nil
            await resolveSource()
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func makeQueue() async {
        guard let store, let context, let exe = source.url else { queue = nil; return }
        let snapshot = await MooringsController.shared?.shellEnvironment.current()
        let environment = EnvironmentBuilder(snapshot: snapshot, paths: paths, home: paths.home)
        let options = TrivyOptions(cacheDirectory: TrivyCLI.defaultCacheDirectory(paths: paths),
                                   dbRepository: SurveyScanSettings.string(SurveyScanSettings.dbRepository),
                                   javaDBRepository: SurveyScanSettings.string(SurveyScanSettings.javaDBRepository),
                                   architecture: "amd64")
        let runner = TrivyScanRunner(cli: TrivyCLI(executable: exe, environment: environment), options: options, store: store, paths: paths,
                                     pullSecretConfig: { cluster, ref in await context.pullSecretConfig(cluster: cluster, ref: ref) })
        let q = ScanQueue(store: store, runner: runner, conditions: conditions, onlyOnPower: { SurveyScanSettings.isOnlyOnPower },
                          observer: SystemScanConditionsObserver(), publish: { [weak self] p in Task { @MainActor in self?.receive(p) } })
        queue = q
        await q.restore()
    }

    fileprivate func receive(_ p: ScanProgress) {
        let finished = progress.state == .running && p.state != .running
        let grew = p.scanned > lastReloadedScanned
        progress = p
        lastReloadedScanned = p.scanned
        if finished || grew { Task { await reloadScans() } }
    }

    func reloadScans() async {
        if let store { scans = (try? await store.allScans()) ?? scans }
    }

    // MARK: Scan requests

    /// The decision the UI shows before a scan: a scan that the energy rules would pause asks "Scan anyway?".
    var wouldPauseOnEnergy: ScanGate.PauseReason? {
        if case .paused(let reason) = ScanGate.decide(trigger: .scheduled, conditions: conditions(), onlyOnPower: SurveyScanSettings.isOnlyOnPower) { reason } else { nil }
    }

    /// Reads the running pods of `sessions`, queues their images and starts. `.manual` overrides the energy rules.
    func scan(sessions: [ClusterSession], trigger: ScanTrigger) async {
        await prepare()
        guard let queue, source.url != nil else { message = "No trivy is available. Set one up first."; return }
        message = nil
        var uses: [ImageUse] = []
        var arch: [ClusterID: String] = [:]
        var clients: [ClusterID: any KubeClientProtocol] = [:]
        for session in sessions where !session.credentialsMissing {
            do {
                let pods = try await session.client.list(Unstructured.self, kind: .pod, namespace: nil, options: ListOptions())
                uses += ImageInventory.build(pods: pods.items.map(\.raw), clusterID: session.config.id)
                clients[session.config.id] = session.client
                if let nodes = try? await session.client.list(Unstructured.self, kind: .node, namespace: nil, options: ListOptions()) {
                    arch[session.config.id] = ImageInventory.dominantArchitecture(nodes: nodes.items.map(\.raw))
                }
            } catch {
                message = "\(session.config.name): \(error.localizedDescription)"
            }
        }
        let merged = ImageInventory.merge(uses)
        var byImage: [ClusterID: [String: [TrivyOperator.WorkloadKey]]] = [:]
        var secrets: [ClusterID: [String: [PullSecretRef]]] = [:]
        for u in uses {
            let key = u.reference.digest ?? u.reference.scanTarget
            byImage[u.clusterID, default: [:]][key, default: []] += u.workloads
            secrets[u.clusterID, default: [:]][u.reference.scanTarget] = u.pullSecrets
        }
        workloadsByImage.merge(byImage) { _, new in new }
        await context?.set(clients: clients, secrets: secrets)
        do {
            var architectures: [String: String] = [:]
            for m in merged { if let a = m.clusters.compactMap({ arch[$0] }).first { architectures[m.reference.scanTarget] = a } }
            try await queue.enqueue(images: merged.map { (image: $0.reference.scanTarget, isMutable: $0.reference.isMutable, clusters: $0.clusters) },
                                    trigger: trigger, architectures: architectures)
            await queue.start(trigger: trigger)
        } catch {
            message = error.localizedDescription
        }
    }

    func pause() async { await queue?.pause() }
    func resume(manual: Bool) async { await queue?.resume(trigger: manual ? .manual : .scheduled) }
    func clearQueue() async { await queue?.cancelAll() }

    /// Test hook: re-evaluates the energy rules now (the real observer calls this on power, Low Power Mode and thermal changes).
    func conditionsChanged() async { await queue?.conditionsChanged() }

    // MARK: Pull-secret opt-in and risks

    func usesPullSecrets(_ clusterID: ClusterID) async -> Bool {
        await prepare()
        return (try? await store?.usesPullSecrets(clusterID: clusterID)) ?? false
    }

    func setUsesPullSecrets(_ on: Bool, clusterID: ClusterID) async {
        await prepare()
        try? await store?.setUsesPullSecrets(on, clusterID: clusterID)
    }
}
