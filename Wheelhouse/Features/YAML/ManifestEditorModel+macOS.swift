import SwiftUI
import Observation
import WheelhouseKit
import WheelhouseDesktop

/// One OpenAPI store per cluster, kept while its session lives (the Manifest Editor, and later First Mate's `explain_field`, share
/// them). Every store draws on ONE 32 MB in-memory budget; a memory-pressure event, the last editor closing and the energy
/// coordinator's release empty it. The disk copies stay, so the next open reads a file instead of the network.
@MainActor
final class SchemaServices {
    static let shared = SchemaServices()

    private struct Entry {
        weak var session: ClusterSession?
        var version: String?
        var store: OpenAPIStore
    }

    private var entries: [ClusterID: Entry] = [:]
    private var openEditors = 0
    private var observer: (any NSObjectProtocol)?
    /// The single in-memory budget (ARCHITECTURE-MAC section 12.3).
    let cache = SharedSchemaCache()
    /// Overridden by tests so nothing is written to the real cache.
    var cacheRoot: URL? = AppPaths.current.caches.appending(path: "schemas", directoryHint: .isDirectory)

    init() {
        // A removed or reconfigured cluster drops its store (and with it the client it holds).
        observer = NotificationCenter.default.addObserver(forName: ClusterEvents.invalidated, object: nil, queue: .main) { [weak self] note in
            guard let id = ClusterEvents.clusterID(from: note) else { return }
            MainActor.assumeIsolated { self?.drop(clusterID: id) }
        }
    }

    var storeCount: Int { entries.count }

    /// The store of `session`. A store is reused only for the very same session object and server version: a rebuilt session has a new
    /// client (new credentials, URL or exec provider) and gets a new store, whatever its cluster ID.
    func store(for session: ClusterSession) async -> OpenAPIStore {
        let version: String?
        if let known = session.version?.gitVersion { version = known } else { version = (try? await session.client.version())?.gitVersion }
        entries = entries.filter { $0.value.session != nil }                       // sessions that no longer exist
        if let entry = entries[session.id], entry.session === session, entry.version == version { return entry.store }
        if let old = entries[session.id] { await old.store.releaseMemory() }
        let store = OpenAPIStore(cluster: session.id, serverVersion: version, cacheRoot: cacheRoot, client: session.client, sharedCache: cache)
        entries[session.id] = Entry(session: session, version: version, store: store)
        return store
    }

    func drop(clusterID: ClusterID) {
        guard let entry = entries.removeValue(forKey: clusterID) else { return }
        Task { await entry.store.releaseMemory() }
    }

    func editorOpened() { openEditors += 1 }

    /// The last editor closing releases the parsed schemas.
    func editorClosed() {
        openEditors = max(0, openEditors - 1)
        if openEditors == 0 { cache.removeAll() }
    }

    /// Memory pressure, or the app going to menu-bar mode: drop every parsed schema.
    static func trim() { shared.cache.removeAll() }
}

/// What the Manifest Editor knows about a cluster: where schemas come from, which kinds exist, and how to look up referenced names.
/// Viewing a resource's YAML does no schema work (no discovery, no version probe, no OpenAPI request): the model is activated by
/// Edit, by the first hover or by a completion request.
@MainActor @Observable
final class ManifestAssistModel: EditorAssisting {
    private(set) var analysis = ManifestAnalysis()
    /// Bumped for every request; a result for an older text is dropped, never shown.
    private(set) var generation = 0
    private(set) var analyzedGeneration = 0
    private(set) var isActive = false
    /// True while activation waits for the cluster (an unreachable one can take about 30 s to give up).
    private(set) var isLoadingSchema = false
    @ObservationIgnored private var schemas: (any ManifestSchemaProviding)?
    @ObservationIgnored private var references: ClusterReferences?
    @ObservationIgnored private var known: [GroupVersionKind] = []
    @ObservationIgnored private let namespace: String?
    @ObservationIgnored private let session: ClusterSession?
    @ObservationIgnored private var activation: Task<Void, Never>?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastText = ""
    /// 250 ms (DESIGN-MAC section 6.8).
    @ObservationIgnored var debounce: Duration = .milliseconds(250)

    /// Lazy: nothing is read from the cluster until ``activate()``.
    init(session: ClusterSession, namespace: String?) {
        self.session = session
        self.namespace = namespace
    }

    /// Ready to use (tests, and callers that already hold a provider).
    init(schemas: (any ManifestSchemaProviding)?, references: ClusterReferences?, known: [GroupVersionKind] = [], namespace: String?) {
        self.session = nil
        self.schemas = schemas
        self.references = references
        self.known = known
        self.namespace = namespace
        self.isActive = true
    }

    var hasSchemas: Bool { schemas != nil }

    /// Opens the schema store, reads discovery for `apiVersion`/`kind` pairs and sets up metadata-only reference lookups.
    func activate() async {
        if isActive { return }
        if let running = activation { await running.value; return }
        guard let session else { isActive = true; return }
        isLoadingSchema = true
        let work = Task { @MainActor [weak self] in
            // The version probe (inside `store(for:)`) and discovery wait on the same cluster: run them side by side.
            let existing = session.discovery, client = session.client
            async let found: DiscoveryInfo? = {
                if let existing { return existing }
                return try? await client.discovery()
            }()
            let store = await SchemaServices.shared.store(for: session)
            let discovery = await found
            guard let self else { return }
            self.isLoadingSchema = false
            self.schemas = store
            self.references = ClusterReferences(client: session.client)
            self.known = (discovery?.topLevel ?? []).compactMap { r in
                guard let v = r.version, !v.isEmpty else { return nil }
                return GroupVersionKind(group: r.group ?? "", version: v, kind: r.kind)
            }
            self.isActive = true
            self.activation = nil
            self.textChanged(self.lastText, immediately: true)      // validate against the schema now that there is one
        }
        activation = work
        await work.value
    }

    /// Analyses `text` after the debounce. A newer call cancels the wait of an older one. Before activation only the YAML itself is
    /// read (syntax, outline, folds).
    func textChanged(_ text: String, immediately: Bool = false) {
        task?.cancel()
        lastText = text
        generation += 1
        let mine = generation
        let analyzer = ManifestAnalyzer(schemas: isActive ? schemas : nil)
        let wait = immediately ? Duration.zero : debounce
        task = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled else { return }
            let result = await analyzer.analyze(text)         // runs off the main actor (`@concurrent`)
            guard !Task.isCancelled, let self, self.generation == mine else { return }
            self.analysis = result
            self.analyzedGeneration = mine
        }
    }

    func reset() {
        task?.cancel()
        generation += 1
        analysis = ManifestAnalysis()
    }

    // MARK: EditorAssisting

    func completions(text: String, offset: Int) async -> ManifestCompletionResult {
        await activate()
        return await ManifestAssist.completions(text: text, offset: offset, schemas: schemas, known: known, references: references, defaultNamespace: namespace)
    }

    func hover(text: String, offset: Int) async -> ManifestHover? {
        await activate()
        return await ManifestAssist.hover(text: text, offset: offset, schemas: schemas)
    }
}

/// Edit, Diff and Live (DESIGN-MAC section 6.8).
enum ManifestSegment: String, CaseIterable, Identifiable {
    case edit = "Edit", diff = "Diff", live = "Live"
    var id: String { rawValue }
}
