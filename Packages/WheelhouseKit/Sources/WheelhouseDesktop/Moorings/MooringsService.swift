#if os(macOS)
import Foundation
import WheelhouseKit

/// What changed in the last scan.
public struct MooringsChange: Sendable, Equatable {
    public var added: [ClusterID] = []
    public var changed: [ClusterID] = []
    public var removed: [ClusterID] = []
    public var isEmpty: Bool { added.isEmpty && changed.isEmpty && removed.isEmpty }
}

/// Builds clients and credential providers for checks (the real implementation is ``DesktopClientFactory``; tests count calls).
public protocol MooringsClientMaking: Sendable {
    func makeClient(config: ClusterConfig, secrets: ClusterSecrets) -> any KubeClientProtocol
    func tokenSource(for config: ClusterConfig, secrets: ClusterSecrets) -> BearerTokenSource?
}

extension DesktopClientFactory: MooringsClientMaking {
    public func makeClient(config: ClusterConfig, secrets: ClusterSecrets) -> any KubeClientProtocol { make(config: config, secrets: secrets) }
    public func tokenSource(for config: ClusterConfig, secrets: ClusterSecrets) -> BearerTokenSource? {
        resolveTokenSource(for: config, secrets: secrets)
    }
}

/// Asks the person to confirm (Touch ID or the password) before changes are allowed on a Production or Production-suggested cluster.
public protocol ChangeAuthorizing: Sendable {
    func authorize(reason: String) async -> Bool
}

public struct DenyingChangeAuthorizer: ChangeAuthorizing {
    public init() {}
    public func authorize(reason: String) async -> Bool { false }
}

public struct FirstRunRow: Identifiable, Sendable, Equatable {
    public var id: ClusterID
    public var context: DiscoveredContext
    /// False for contexts that cannot be added: unsupported auth, shadowed, or blocked in development builds.
    public var selectable: Bool
    public var unselectableReason: String?
    public var defaultSelected: Bool
}

/// The user's choice for one first-run row.
public struct FirstRunChoice: Sendable, Equatable {
    public var selected: Bool
    /// What the environment popup showed when Add was pressed (the suggestion, or the user's pick).
    public var environment: ClusterEnvironment?
    /// True when the user picked the environment (rather than accepting the suggestion).
    public var environmentPicked: Bool
    public var allowChanges: Bool
    public init(selected: Bool, environment: ClusterEnvironment? = nil, environmentPicked: Bool = false, allowChanges: Bool = false) {
        self.selected = selected
        self.environment = environment
        self.environmentPicked = environmentPicked
        self.allowChanges = allowChanges
    }
}

public struct MooringsConfiguration: Sendable {
    public var gate: DevSafetyPolicy
    public var home: URL
    public var explicitTestKubeconfig: URL?
    /// `KUBECONFIG` from the shell snapshot (already sanitised by the gate in `ShellEnvironment`).
    public var shellKubeconfig: @Sendable () async -> String?
    /// Safety rescan interval; only runs while a window is visible.
    public var safetyRescanInterval: TimeInterval
    /// Where the safety rescan registers (tests use their own).
    public var registry: PeriodicTaskRegistry

    public init(gate: DevSafetyPolicy = .current, home: URL = DevSafetyPolicy.accountHome,
                explicitTestKubeconfig: URL? = KubeconfigDiscoveryPolicy.explicitTestKubeconfig(),
                shellKubeconfig: @escaping @Sendable () async -> String? = { nil }, safetyRescanInterval: TimeInterval = 600,
                registry: PeriodicTaskRegistry = .shared) {
        self.gate = gate
        self.home = home
        self.explicitTestKubeconfig = explicitTestKubeconfig
        self.shellKubeconfig = shellKubeconfig
        self.safetyRescanInterval = safetyRescanInterval
        self.registry = registry
    }
}

/// Moorings: kubeconfig discovery, watching, change detection, checks and adoption (ARCHITECTURE-MAC §4).
///
/// - Sources: while the gate is active the ONLY source is the explicit test file (plus user files that are not under `~/.kube`).
/// - Watching is FSEvents only; the 10-minute safety rescan is a `PeriodicTask` that stops while no window is visible.
/// - A context found later that is suggested as Production is NOT probed until the user clicks Check.
public actor MooringsService: MooringsSourceAdding {
    public nonisolated let state: MooringsState
    private let config: MooringsConfiguration
    private let loader: KubeconfigLoader
    private let broker: ExecCredentialBroker?
    private let clients: any MooringsClientMaking
    private let authorizer: any ChangeAuthorizing
    private let onChange: @Sendable (MooringsChange) -> Void
    private let now: @Sendable () -> Date

    private var watcher: FileWatcher?
    private var safetyTask: PeriodicTask?
    private var previous: [ClusterID: DiscoveredContext] = [:]
    private var previousHashes: [String: String] = [:]
    private var hasScanned = false
    /// Files that could not be read or are refused, by path (shown in Settings → Moorings).
    public private(set) var issues: [String: String] = [:]
    public private(set) var scanCount = 0

    public init(config: MooringsConfiguration, state: MooringsState, clients: any MooringsClientMaking, broker: ExecCredentialBroker? = nil,
                authorizer: any ChangeAuthorizing = DenyingChangeAuthorizer(), now: @escaping @Sendable () -> Date = { Date() },
                onChange: @escaping @Sendable (MooringsChange) -> Void = { _ in }) {
        self.config = config
        self.state = state
        self.loader = KubeconfigLoader(gate: config.gate)
        self.clients = clients
        self.broker = broker
        self.authorizer = authorizer
        self.now = now
        self.onChange = onChange
    }

    // MARK: MooringsSourceAdding

    public nonisolated var isAvailable: Bool { true }

    /// Adds the file (by realpath) as a user file source. Refused under `~/.kube` while the gate is active.
    public func addFileSource(_ url: URL) async throws {
        try config.gate.assertReadable(url)
        let real = url.resolvingSymlinksInPath().standardizedFileURL
        try config.gate.assertReadable(real)
        let source = MooringsSource(kind: .userFile, path: real.path)
        try state.preferences.update { if !$0.userSources.contains(source) { $0.userSources.append(source) } }
        await rescan()
    }

    public func addFolderSource(_ url: URL, recursive: Bool = false) async throws {
        try config.gate.assertReadable(url)
        let real = url.resolvingSymlinksInPath().standardizedFileURL
        try config.gate.assertReadable(real)
        let source = MooringsSource(kind: .userFolder, path: real.path, recursive: recursive)
        try state.preferences.update { if !$0.userSources.contains(source) { $0.userSources.append(source) } }
        await rescan()
    }

    public func removeSource(_ source: MooringsSource) async throws {
        try state.preferences.update { $0.userSources.removeAll { $0 == source } }
        await rescan()
    }

    // MARK: Lifecycle

    /// First scan, then watching. Safe to call once.
    public func start() async {
        await rescan()
        let watcher = FileWatcher { [weak self] change in
            guard let self else { return }
            Task { await self.handle(change) }
        }
        self.watcher = watcher
        updateWatcher()
        // Low-frequency safety rescan: only while a window is visible (no hidden cadence).
        let task = PeriodicTask(name: "moorings.safety-rescan", interval: config.safetyRescanInterval, hiddenInterval: nil, registry: config.registry) { [weak self] in
            await self?.rescan()
        }
        task.start()
        safetyTask = task
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
        appliedWatch = nil
        safetyTask?.stop()
        safetyTask = nil
    }

    /// True while the watcher exists (tests).
    public var isWatching: Bool { watcher?.isRunning ?? false }

    private func handle(_ change: FileChange) async {
        await rescan()
    }

    // MARK: Scanning

    /// The sources for the current preferences and gate.
    func resolvedSources() async -> [(source: MooringsSource, urls: [URL])] {
        let prefs = state.preferences.value
        let policy = KubeconfigDiscoveryPolicy(gate: config.gate)
        var out: [(MooringsSource, [URL])] = []
        let shell = policy.sanitizedShellKubeconfig(await config.shellKubeconfig())
        if config.gate.isActive {
            if let files = try? policy.defaultSources(explicitTest: config.explicitTestKubeconfig, shellKubeconfig: shell), !files.isEmpty {
                out.append((MooringsSource(kind: .explicitTest, path: files[0].path), files))
            }
        } else if prefs.shellKubeconfigEnabled, let files = try? policy.defaultSources(explicitTest: nil, shellKubeconfig: shell) {
            out.append((MooringsSource(kind: .defaultSet), files))
        }
        if !config.gate.isActive {
            if prefs.homeFilesEnabled == true {
                let kube = config.home.appending(path: ".kube", directoryHint: .isDirectory)
                let files = KubeconfigLoader.candidateFiles(in: kube, recursive: false).filter { $0.lastPathComponent != "config" }
                    + KubeconfigLoader.candidateFiles(in: kube.appending(path: "configs", directoryHint: .isDirectory), recursive: false)
                out.append((MooringsSource(kind: .homeFiles), files))
            }
            let landfall = AppPaths(gateActive: false, bundleID: AppPaths.releaseBundleID, home: config.home).landfallKubeconfig
            if FileManager.default.fileExists(atPath: landfall.path) { out.append((MooringsSource(kind: .landfall, path: landfall.path), [landfall])) }
        }
        for s in prefs.userSources {
            guard let p = s.path else { continue }
            out.append((s, [URL(fileURLWithPath: p)]))
        }
        return out
    }

    private struct ScanOutcome {
        var contexts: [DiscoveredContext] = []
        var hashes: [String: String] = [:]
        var issues: [String: String] = [:]
        var files: Set<String> = []
        var folders: [String: Bool] = [:]
    }

    private func scan() async -> ScanOutcome {
        var outcome = ScanOutcome()
        var byID: [ClusterID: DiscoveredContext] = [:]
        var order: [ClusterID] = []
        func absorb(_ set: LoadedSet, sourceID: String) {
            outcome.hashes.merge(set.fileHashes) { a, _ in a }
            outcome.issues.merge(set.issues) { a, _ in a }
            for lc in set.contexts {
                let key = DiscoveredContextKey(definingFile: lc.definingFile, contextName: lc.context.name)
                if var existing = byID[key.clusterID] {
                    if !existing.sourceIDs.contains(sourceID) { existing.sourceIDs.append(sourceID); byID[key.clusterID] = existing }
                    continue
                }
                byID[key.clusterID] = DiscoveredContext.make(key: key, sourceID: sourceID, context: lc.context, isCurrent: lc.isCurrent,
                                                             shadowedBy: lc.shadowedBy, gate: config.gate)
                order.append(key.clusterID)
            }
        }
        for (source, urls) in await resolvedSources() {
            do {
                switch source.kind {
                case .defaultSet, .explicitTest:
                    absorb(try loader.loadDefaultSet(urls), sourceID: source.id)
                    for u in urls { outcome.files.insert(u.path) }
                case .homeFiles, .landfall, .userFile:
                    for u in urls { absorb(try loader.loadStandalone(u), sourceID: source.id); outcome.files.insert(u.path) }
                    if source.kind == .homeFiles {
                        let kube = config.home.appending(path: ".kube", directoryHint: .isDirectory)
                        outcome.folders[kube.path] = false
                        outcome.folders[kube.appending(path: "configs", directoryHint: .isDirectory).path] = false
                    }
                case .userFolder:
                    for u in urls {
                        absorb(try loader.loadFolder(u, recursive: source.recursive), sourceID: source.id)
                        outcome.folders[u.path] = source.recursive
                    }
                }
            } catch let e as DevSafetyError {
                for u in urls { outcome.issues[u.path] = e.localizedDescription }
            } catch {
                for u in urls { outcome.issues[u.path] = error.localizedDescription }
            }
        }
        // Duplicate names across standalone files are separate clusters, told apart by the file name.
        let nameCounts = Dictionary(grouping: order.compactMap { byID[$0] }.filter { $0.shadowedBy == nil }, by: { $0.context.name }).mapValues(\.count)
        for id in order {
            guard var c = byID[id], (nameCounts[c.context.name] ?? 0) > 1 else { continue }
            c.displayName = "\(c.context.name) — \(c.fileName)"
            byID[id] = c
        }
        outcome.contexts = order.compactMap { byID[$0] }
        return outcome
    }

    /// Re-reads every source, diffs by identity and publishes the change. Content hashes make an unchanged file a no-op.
    @discardableResult
    public func rescan() async -> MooringsChange {
        let outcome = await scan()
        scanCount += 1
        issues = outcome.issues
        if hasScanned, outcome.hashes == previousHashes, Set(outcome.contexts.map(\.id)) == Set(previous.keys) {
            // Nothing changed on disk: stop here (no diff, no events).
            updateWatcher(files: outcome.files, folders: outcome.folders)
            return MooringsChange()
        }
        let change = apply(outcome)
        updateWatcher(files: outcome.files, folders: outcome.folders)
        if !change.isEmpty { onChange(change) }
        return change
    }

    private var lastWatched: (files: Set<String>, folders: [String: Bool]) = ([], [:])
    /// What the running stream was created with: it is recreated only when the watched set actually changes.
    private var appliedWatch: (files: Set<String>, folders: [String: Bool])?

    private func updateWatcher(files: Set<String>? = nil, folders: [String: Bool]? = nil) {
        if let files, let folders { lastWatched = (files, folders) }
        guard let watcher else { return }
        if let applied = appliedWatch, applied.files == lastWatched.files, applied.folders == lastWatched.folders, watcher.isRunning { return }
        watcher.update(files: lastWatched.files, folders: lastWatched.folders)
        appliedWatch = lastWatched
    }

    private func apply(_ outcome: ScanOutcome) -> MooringsChange {
        let newByID = Dictionary(outcome.contexts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var change = MooringsChange()
        let prefs = state.preferences.value
        let isFirstScan = !hasScanned
        var overrideChanges: [ClusterID: DiscoveredOverride?] = [:]
        let stamp = now()

        for ctx in outcome.contexts {
            let id = ctx.id
            var o = state.overrides.override(for: id)
            if let old = previous[id], old.fingerprint != ctx.fingerprint { change.changed.append(id) }
            if let existing = o, existing.added {
                var updated = existing
                updated.sourceRemovedAt = nil
                updated.lastKnown = lastKnown(ctx)
                if updated != existing { overrideChanges[id] = updated }
                if previous[id] == nil, !isFirstScan { change.added.append(id) }
            } else if o == nil, prefs.firstRunCompleted, ctx.isUsable, !ctx.blockedInDevelopment {
                // Found after the first run: appears read-only with a "New" badge. Not probed if suggested as Production.
                var fresh = DiscoveredOverride()
                fresh.added = true
                fresh.isNew = true
                fresh.addedAt = stamp
                fresh.lastKnown = lastKnown(ctx)
                overrideChanges[id] = fresh
                o = fresh
                change.added.append(id)
            }
        }
        // Contexts that disappeared: their cluster enters Source removed (overrides kept 30 days).
        for (id, _) in previous where newByID[id] == nil {
            if var o = state.overrides.override(for: id), o.added, o.sourceRemovedAt == nil {
                o.sourceRemovedAt = stamp
                overrideChanges[id] = o
            }
            change.removed.append(id)
        }
        if !overrideChanges.isEmpty { try? state.overrides.apply(overrideChanges) }
        try? state.overrides.sweep(now: stamp)

        state.replace(contexts: outcome.contexts)
        previous = newByID
        previousHashes = outcome.hashes
        hasScanned = true

        // A changed context: sessions, watches and the credential cache of its key are dropped and rebuilt.
        if !change.changed.isEmpty {
            let ids = change.changed
            if let broker {
                let files = Set(ids.compactMap { newByID[$0]?.key.definingFile })
                Task { for f in files { await broker.forget(kubeconfigPath: f) } }
            }
            Task { @MainActor in ids.forEach { ClusterEvents.postInvalidated($0, removed: false) } }
        }
        return change
    }

    private func lastKnown(_ ctx: DiscoveredContext) -> LastKnownContext? {
        guard let server = ctx.context.server else { return nil }
        return LastKnownContext(definingFile: ctx.key.definingFile, contextName: ctx.key.contextName, server: server.absoluteString,
                                tlsServerName: ctx.context.tlsServerName, authKind: DiscoveredSecrets.authKind(of: ctx.context),
                                insecureSkipTLSVerify: ctx.context.insecureSkipTLSVerify, namespace: ctx.context.namespace,
                                displayName: ctx.displayName, suggestedEnvironment: ctx.suggestion?.environment)
    }

    // MARK: First run

    /// Everything the first-run sheet lists: contexts that were not decided yet.
    public func firstRunRows() -> [FirstRunRow] {
        state.contexts.filter { let o = state.overrides.override(for: $0.id); return o?.added != true && o?.hidden != true }.map { ctx in
            var reason: String?
            if let by = ctx.shadowedBy { reason = "Shadowed by \(by)" }
            else if ctx.blockedInDevelopment { reason = "Blocked in development builds" }
            else if ctx.context.status != .ready { reason = ctx.context.unsupportedReason ?? "Unsupported" }
            return FirstRunRow(id: ctx.id, context: ctx, selectable: reason == nil, unselectableReason: reason, defaultSelected: reason == nil)
        }
    }

    /// Applies the sheet: ticked rows become clusters, read-only; changes are allowed only for a row whose environment the user
    /// picked. `Add` is the moment a Production suggestion is applied. Marks the first run complete.
    public func completeFirstRun(choices: [ClusterID: FirstRunChoice]) async throws {
        var changes: [ClusterID: DiscoveredOverride?] = [:]
        let stamp = now()
        for (id, choice) in choices where choice.selected {
            guard let ctx = state.context(for: id), ctx.isUsable, !ctx.blockedInDevelopment else { continue }
            var o = state.overrides.override(for: id) ?? DiscoveredOverride()
            o.added = true
            o.hidden = false
            o.addedAt = stamp
            o.environment = choice.environment ?? ctx.suggestion?.environment
            o.environmentChosen = choice.environmentPicked && choice.environment != nil
            o.readOnly = true
            o.lastKnown = lastKnown(ctx)
            if choice.allowChanges, o.environmentChosen {
                let env = o.environment ?? .development
                if env == .production || ctx.isSuggestedProduction {
                    guard await authorizer.authorize(reason: "Allow changes on \(ctx.displayName)") else { changes[id] = o; continue }
                }
                o.readOnly = false
            }
            changes[id] = o
        }
        try state.overrides.apply(changes)
        try state.preferences.update { $0.firstRunCompleted = true }
        onChange(MooringsChange(added: Array(changes.keys)))
    }

    /// "Choose Later": nothing is added and the sheet stays available.
    public func deferFirstRun() {}

    // MARK: Allow changes, opening, removal

    /// Leaves read-only. Needs an explicitly chosen environment, and Touch ID or the password for Production and Production-suggested.
    public func allowChanges(id: ClusterID, environment: ClusterEnvironment) async throws {
        guard var o = state.overrides.override(for: id), o.added else { return }
        let suggestedProd = state.context(for: id)?.isSuggestedProduction ?? (o.lastKnown?.suggestedEnvironment == .production)
        if environment == .production || o.environment == .production || suggestedProd {
            guard await authorizer.authorize(reason: "Allow changes on \(o.name ?? o.lastKnown?.displayName ?? "this cluster")") else {
                throw MooringsError.authorizationDenied
            }
        }
        o.environment = environment
        o.environmentChosen = true
        o.readOnly = false
        o.contactApproved = true
        try state.overrides.apply([id: o])
        onChange(MooringsChange(changed: [id]))
    }

    /// Opening a cluster approves contact for a Production-suggested one (owner decision 10) and clears its New badge.
    public func markOpened(_ id: ClusterID) throws {
        guard var o = state.overrides.override(for: id), o.added else { return }
        o.contactApproved = true
        o.isNew = false
        try state.overrides.apply([id: o])
        onChange(MooringsChange(changed: [id]))
    }

    /// Moves the overrides of a vanished context to the cluster of `newKey` (Re-link…).
    public func relink(from oldID: ClusterID, to newKey: DiscoveredContextKey) throws {
        guard let old = state.overrides.override(for: oldID) else { return }
        let newID = newKey.clusterID
        var moved = old
        moved.sourceRemovedAt = nil
        try state.overrides.apply([newID: moved, oldID: nil])
        onChange(MooringsChange(added: [newID], removed: [oldID]))
    }

    // MARK: Checks

    /// The user clicked Check. The ONLY way a Production-suggested context is contacted before it is opened.
    @discardableResult
    public func check(_ id: ClusterID) async -> ClusterCheckResult {
        let wasHeld = state.isContactHeld(id)
        state.approveContact(id)
        if var o = state.overrides.override(for: id), !o.contactApproved {
            o.contactApproved = true
            try? state.overrides.apply([id: o])
        }
        // The held client is replaced by a real one.
        if wasHeld { onChange(MooringsChange(changed: [id])) }
        return await runCheck(id)
    }

    /// First-run checks (limit 4 in parallel). Rows suggested as Production are skipped entirely: not contacted, no plugin run.
    public func startFirstRunChecks(ids: [ClusterID]) async {
        let eligible = ids.filter { id in
            guard let ctx = state.context(for: id), ctx.isUsable, !ctx.blockedInDevelopment else { return false }
            return !ctx.isSuggestedProduction
        }
        for id in ids where !eligible.contains(id) { state.setCheck(.notChecked, for: id) }
        await withTaskGroup(of: Void.self) { group in
            var iterator = eligible.makeIterator()
            var running = 0
            func next() -> ClusterID? { iterator.next() }
            while running < 4, let id = next() { running += 1; group.addTask { [self] in _ = await runCheck(id) } }
            while await group.next() != nil {
                running -= 1
                if let id = next() { running += 1; group.addTask { [self] in _ = await runCheck(id) } }
            }
        }
    }

    private func runCheck(_ id: ClusterID) async -> ClusterCheckResult {
        guard let ctx = state.context(for: id) else { return .unreachable("This context is gone.") }
        if ctx.blockedInDevelopment {
            let r = ClusterCheckResult.blocked("Blocked in development builds")
            state.setCheck(.result(r), for: id)
            onChange(MooringsChange(changed: []))
            return r
        }
        state.setCheck(.checking, for: id)
        let override = state.overrides.override(for: id) ?? DiscoveredOverride()
        guard let cfg = state.makeConfig(for: ctx, override: override) else { return finish(id, .unreachable("The context has no server.")) }
        let secrets = DiscoveredSecrets.resolve(ctx.context, gate: config.gate)
        // Plugin problems are classified precisely before any request is made.
        if case .dynamic(let provider)? = clients.tokenSource(for: cfg, secrets: secrets) {
            do { _ = try await provider.authorization() } catch let e as ExecCredentialError {
                switch e {
                case .pluginMissing(let command, _, _): return finish(id, .pluginMissing((command as NSString).lastPathComponent))
                case .signInRequired: return finish(id, .needsSignIn)
                case .failed, .invalidOutput: return finish(id, .needsSignIn)
                case .timedOut: return finish(id, .unreachable("The credential plugin timed out."))
                default: return finish(id, .unreachable(e.localizedDescription))
                }
            } catch { return finish(id, .unreachable(error.localizedDescription)) }
        }
        let client = clients.makeClient(config: cfg, secrets: secrets)
        let start = ContinuousClock.now
        do {
            let version = try await client.version()
            let d = start.duration(to: .now)
            let ms = Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
            return finish(id, .reachable(latencyMilliseconds: ms, version: version.gitVersion))
        } catch KubeError.unauthorized {
            return finish(id, .needsSignIn)
        } catch {
            return finish(id, .unreachable(error.localizedDescription))
        }
    }

    private func finish(_ id: ClusterID, _ result: ClusterCheckResult) -> ClusterCheckResult {
        state.setCheck(.result(result), for: id)
        onChange(MooringsChange(changed: []))
        return result
    }

    // MARK: Adopt

    /// Everything the app needs to create the Keychain cluster. Nothing is stored here.
    public struct Adoption: Sendable {
        public var config: ClusterConfig
        public var secrets: ClusterSecrets
        public var execAdoption: ExecAdoption?
    }

    /// Copies a discovered context's credentials into a new Keychain cluster (`origin = nil`), keeping the overrides. An exec context
    /// keeps its plugin stanza in `MacClusterSettings.execAdopted` and the Keychain item holds the CA only; it never syncs.
    /// iCloud sync starts OFF: the person turns it on per cluster (disabled for exec and loopback clusters).
    public func prepareAdoption(id: ClusterID) throws -> Adoption {
        guard let ctx = state.context(for: id), let server = ctx.context.server else { throw MooringsError.notAvailable }
        guard !ctx.blockedInDevelopment else { throw DevSafetyError.hostNotAllowed(server.host() ?? "") }
        let override = state.overrides.override(for: id) ?? DiscoveredOverride()
        guard var cluster = state.makeConfig(for: ctx, override: override) else { throw MooringsError.notAvailable }
        var secrets = DiscoveredSecrets.resolve(ctx.context, gate: config.gate)
        var exec: ExecAdoption?
        if let spec = ctx.context.exec {
            exec = ExecAdoption(spec: spec, specHash: DiscoveredContext.execHash(spec), kubeconfigPath: ctx.key.definingFile)
            secrets = ClusterSecrets(caPEM: secrets.caPEM)
        } else if secrets.isMissingCredentials(for: cluster.authKind) {
            throw MooringsError.credentialsUnreadable
        }
        cluster.id = UUID().uuidString.lowercased()
        cluster.origin = nil
        cluster.iCloudSync = false
        cluster.createdAt = now()
        cluster.modifiedAt = now()
        return Adoption(config: cluster, secrets: secrets, execAdoption: exec)
    }
}

public enum MooringsError: Error, Equatable, Sendable, LocalizedError {
    case authorizationDenied
    case notAvailable
    case credentialsUnreadable
    public var errorDescription: String? {
        switch self {
        case .authorizationDenied: "Changes were not allowed."
        case .notAvailable: "This context is not available any more."
        case .credentialsUnreadable: "The credential files of this context could not be read, so it can’t be adopted."
        }
    }
}

public extension MooringsService.Adoption {
    /// Creates the Keychain cluster. The exec stanza is stored first so the sync block applies to the very first save.
    @MainActor
    func commit(registry: ClusterRegistry, settings: MacClusterSettingsStore) throws {
        if let execAdoption { try settings.update(config.id) { $0.execAdopted = execAdoption } }
        try registry.add(config, secrets: secrets)
        registry.reloadFromStore()
    }
}
#endif
