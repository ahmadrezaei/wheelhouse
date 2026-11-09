import SwiftUI
import Observation
import WheelhouseKit
import WheelhouseDesktop

/// One OpenAPI store per cluster and server version, kept for the life of the app (the Manifest Editor, and later First Mate's
/// `explain_field`, share them). Memory is capped per store at 32 MB; a memory-pressure event empties them all.
@MainActor
final class SchemaServices {
    static let shared = SchemaServices()

    private var stores: [String: OpenAPIStore] = [:]
    /// Overridden by tests so nothing is written to the real cache.
    var cacheRoot: URL? = AppPaths.current.caches.appending(path: "schemas", directoryHint: .isDirectory)

    func store(for session: ClusterSession) async -> OpenAPIStore {
        let version: String?
        if let known = session.version?.gitVersion { version = known } else { version = (try? await session.client.version())?.gitVersion }
        // The session object is part of the key: a rebuilt session (new credentials, URL or exec provider) has a new client.
        let key = "\(session.id)|\(version ?? "")|\(ObjectIdentifier(session).hashValue)"
        if let existing = stores[key] { return existing }
        let store = OpenAPIStore(cluster: session.id, serverVersion: version, cacheRoot: cacheRoot, client: session.client)
        stores = stores.filter { !$0.key.hasPrefix("\(session.id)|") }        // an upgraded server replaces the old store
        stores[key] = store
        return store
    }

    /// Memory pressure: drop every parsed schema. The disk copies stay, so the next use reads a file instead of the network.
    static func trim() {
        let all = Array(shared.stores.values)
        Task { for store in all { await store.trimMemory() } }
    }
}

/// What the Manifest Editor knows about a cluster: where schemas come from, which kinds exist, and how to look up referenced names.
@MainActor @Observable
final class ManifestAssistModel: EditorAssisting {
    private(set) var analysis = ManifestAnalysis()
    /// Bumped for every request; a result for an older text is dropped, never shown.
    private(set) var generation = 0
    private(set) var analyzedGeneration = 0
    @ObservationIgnored private let schemas: (any ManifestSchemaProviding)?
    @ObservationIgnored private let references: ClusterReferences?
    @ObservationIgnored private var known: [GroupVersionKind]
    @ObservationIgnored private let namespace: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// 250 ms (DESIGN-MAC section 6.8).
    @ObservationIgnored var debounce: Duration = .milliseconds(250)

    init(schemas: (any ManifestSchemaProviding)?, references: ClusterReferences?, known: [GroupVersionKind] = [], namespace: String?) {
        self.schemas = schemas
        self.references = references
        self.known = known
        self.namespace = namespace
    }

    /// For a live session: the cluster's store, discovery for `apiVersion`/`kind` pairs, and metadata-only reference lookups.
    static func make(session: ClusterSession, namespace: String?) async -> ManifestAssistModel {
        let store = await SchemaServices.shared.store(for: session)
        let model = ManifestAssistModel(schemas: store, references: ClusterReferences(client: session.client), namespace: namespace)
        await model.loadKinds(session: session)
        return model
    }

    private func loadKinds(session: ClusterSession) async {
        let discovery: DiscoveryInfo?
        if let d = session.discovery { discovery = d } else { discovery = try? await session.client.discovery() }
        known = (discovery?.topLevel ?? []).compactMap { r in
            guard let v = r.version, !v.isEmpty else { return nil }
            return GroupVersionKind(group: r.group ?? "", version: v, kind: r.kind)
        }
    }

    var hasSchemas: Bool { schemas != nil }

    /// Analyses `text` after the debounce. A newer call cancels the wait of an older one.
    func textChanged(_ text: String, immediately: Bool = false) {
        task?.cancel()
        generation += 1
        let mine = generation
        let analyzer = ManifestAnalyzer(schemas: schemas)
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
        await ManifestAssist.completions(text: text, offset: offset, schemas: schemas, known: known, references: references, defaultNamespace: namespace)
    }

    func hover(text: String, offset: Int) async -> ManifestHover? {
        await ManifestAssist.hover(text: text, offset: offset, schemas: schemas)
    }
}

/// Edit, Diff and Live (DESIGN-MAC section 6.8).
enum ManifestSegment: String, CaseIterable, Identifiable {
    case edit = "Edit", diff = "Diff", live = "Live"
    var id: String { rawValue }
}
