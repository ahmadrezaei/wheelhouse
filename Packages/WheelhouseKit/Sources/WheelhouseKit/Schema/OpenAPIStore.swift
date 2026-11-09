import Foundation
import CryptoKit

/// Reads a cluster's OpenAPI v3 schemas on demand and keeps them (ARCHITECTURE-MAC section 6.8, M7).
///
/// - `/openapi/v3` lists every group-version with a `serverRelativeURL` that carries a content hash. A document is fetched only
///   when a kind of that group-version is needed, and the hash makes the download immutable: it is written once under
///   `<cache>/<cluster>/<server version>/` and read from there until the cluster serves a different hash.
/// - Parsed documents live in a ``SchemaMemoryCache`` capped at 32 MB (least recently used goes first).
/// - When the cluster does not serve OpenAPI (or the user may not read it) the bundled schema of the nearest minor version answers.
/// - The index is not immutable: it is read again after a few minutes and whenever a kind is missing (a CRD installed meanwhile).
public actor OpenAPIStore: ManifestSchemaProviding {
    public typealias Fetch = @Sendable (String) async throws -> Data

    private let fetch: Fetch
    private let cacheRoot: URL?
    private let clusterKey: String
    private let serverVersion: String?
    private let bundled: BundledSchemas
    private let indexTTL: TimeInterval
    private let minRefresh: TimeInterval
    private let clock: @Sendable () -> Date

    private let cache: SharedSchemaCache
    private var index: [String: String]?
    private var indexAt: Date?
    private var indexTask: Task<[String: String]?, Never>?
    /// Documents that could not be read, for a while (typing must not mean a request per pause).
    private var failedDocuments: [String: Date] = [:]
    private static let failureMemory: TimeInterval = 30
    private var inflight: [String: Task<Loaded?, Never>] = [:]
    private var prunedOldVersions = false
    /// Where the last answer came from.
    public private(set) var lastSource: SchemaSource?
    /// How many documents were downloaded (tests).
    public private(set) var downloads = 0

    public init(cluster: String, serverVersion: String?, cacheRoot: URL?, bundled: BundledSchemas = .standard, sharedCache: SharedSchemaCache,
         indexTTL: TimeInterval = 300, minRefresh: TimeInterval = 5, clock: @escaping @Sendable () -> Date = { Date() }, fetch: @escaping Fetch) {
        self.clusterKey = cluster
        self.serverVersion = serverVersion
        self.cacheRoot = cacheRoot
        self.bundled = bundled
        self.cache = sharedCache
        self.indexTTL = indexTTL
        self.minRefresh = minRefresh
        self.clock = clock
        self.fetch = fetch
    }

    public init(cluster: String, serverVersion: String?, cacheRoot: URL?, bundled: BundledSchemas = .standard,
                memoryLimit: Int = 32 * 1024 * 1024, indexTTL: TimeInterval = 300, minRefresh: TimeInterval = 5,
                clock: @escaping @Sendable () -> Date = { Date() }, fetch: @escaping Fetch) {
        self.clusterKey = cluster
        self.serverVersion = serverVersion
        self.cacheRoot = cacheRoot
        self.bundled = bundled
        self.cache = SharedSchemaCache(limit: memoryLimit)
        self.indexTTL = indexTTL
        self.minRefresh = minRefresh
        self.clock = clock
        self.fetch = fetch
    }

    /// A store reading through a client's OpenAPI seam. Give it the plain client: wrappers that strip or refuse do not forward it.
    public init(cluster: String, serverVersion: String?, cacheRoot: URL?, client: any KubeClientProtocol, bundled: BundledSchemas = .standard,
                sharedCache: SharedSchemaCache = SharedSchemaCache()) {
        self.init(cluster: cluster, serverVersion: serverVersion, cacheRoot: cacheRoot, bundled: bundled, sharedCache: sharedCache) { path in
            try await client.openAPIDocument(path: path)
        }
    }

    // MARK: Lookup

    public func kindSchema(for gvk: GroupVersionKind) async -> KindSchema? {
        let gv = gvk.groupVersionPath
        if var idx = await currentIndex(refresh: false) {
            if let found = await clusterSchema(gvk, gv: gv, index: idx) { return found }
            if canRefresh, let fresh = await currentIndex(refresh: true) {
                idx = fresh
                if let found = await clusterSchema(gvk, gv: gv, index: idx) { return found }
            }
            return nil
        }
        return bundledSchema(gvk, gv: gv)
    }

    /// Releases every parsed document of every store sharing the cache (memory pressure). The disk copies stay.
    public func trimMemory() { cache.removeAll() }

    /// Releases this cluster's parsed documents only (its last editor closed, or the cluster went away).
    public func releaseMemory() { cache.remove(prefix: "cluster:\(clusterKey)|") }

    /// The bytes the (possibly shared) cache holds, by its own estimate.
    public var memoryCost: Int { cache.totalCost }
    public var memoryLimit: Int { cache.limit }

    // MARK: Cluster

    private var canRefresh: Bool { indexAt.map { clock().timeIntervalSince($0) >= minRefresh } ?? true }

    private func currentIndex(refresh: Bool) async -> [String: String]? {
        if !refresh, let index, let at = indexAt, clock().timeIntervalSince(at) < indexTTL { return index }
        // An index that could not be read is not asked for again for a while.
        if !refresh, index == nil, let at = indexAt, clock().timeIntervalSince(at) < max(minRefresh, 30) { return nil }
        if let running = indexTask { return await running.value ?? index }
        let fetch = self.fetch
        let task = Task { await Self.fetchIndex(fetch) }
        indexTask = task
        let fetched = await task.value
        indexTask = nil
        indexAt = clock()
        if let fetched { index = fetched }
        // Keep serving a stale index across a blip; with none, the bundled schema answers.
        return fetched ?? index
    }

    @concurrent
    private static func fetchIndex(_ fetch: Fetch) async -> [String: String]? {
        guard let data = try? await fetch("/openapi/v3"), let root = try? JSONValue.fastParse(data) else { return nil }
        var found: [String: String] = [:]
        for (gv, entry) in root["paths"]?.objectValue ?? [:] {
            if let url = entry["serverRelativeURL"]?.stringValue { found[gv] = url }
        }
        return found
    }

    private func clusterSchema(_ gvk: GroupVersionKind, gv: String, index: [String: String]) async -> KindSchema? {
        guard let url = index[gv], let doc = await document(gv: gv, url: url), let schema = doc.schema(for: gvk) else { return nil }
        lastSource = .cluster
        return KindSchema(document: doc.document, schema: schema, source: .cluster)
    }

    private func document(gv: String, url: String) async -> LoadedSchemaDocument? {
        let key = "cluster:\(clusterKey)|\(url)"
        if let hit = cache.value(for: key) { return hit }
        if let failed = failedDocuments[key], clock().timeIntervalSince(failed) < Self.failureMemory { return nil }
        if let running = inflight[key] { return await running.value?.document }
        let directory = versionDirectory()
        let fetch = self.fetch
        let task = Task { await Self.load(gv: gv, url: url, directory: directory, fetch: fetch) }
        inflight[key] = task
        let loaded = await task.value
        inflight[key] = nil
        if let loaded {
            if loaded.downloaded { downloads += 1; prepareDirectory() }
            cache.insert(loaded.document, for: key)
            failedDocuments[key] = nil
            return loaded.document
        }
        failedDocuments[key] = clock()
        return nil
    }

    // MARK: Disk

    private func versionDirectory() -> URL? {
        guard let cacheRoot else { return nil }
        // Both names come from the server or the user: they are hashed, so no value can climb out of its folder.
        return cacheRoot.appending(path: Self.digest(clusterKey), directoryHint: .isDirectory)
            .appending(path: Self.digest(serverVersion ?? "unknown"), directoryHint: .isDirectory)
    }

    /// After the first download: drop folders of older server versions of this cluster.
    private func prepareDirectory() {
        guard !prunedOldVersions, let directory = versionDirectory() else { return }
        prunedOldVersions = true
        let parent = directory.deletingLastPathComponent()
        for sibling in (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] where sibling.lastPathComponent != directory.lastPathComponent {
            try? FileManager.default.removeItem(at: sibling)
        }
        Self.pruneDisk(root: cacheRoot, maxBytes: Self.diskLimit)
    }

    static let diskLimit = 512 * 1024 * 1024

    struct Loaded: Sendable { var document: LoadedSchemaDocument; var downloaded: Bool }

    /// Disk first, then the network. Runs off the actor: parsing a core document takes tens of milliseconds.
    @concurrent
    private static func load(gv: String, url: String, directory: URL?, fetch: Fetch) async -> Loaded? {
        let hash = URLComponents(string: url)?.queryItems?.first { $0.name == "hash" }?.value
        let file = hash.flatMap { h in directory?.appending(path: "\(digest("\(gv)|\(h)")).json") }
        if let file, let data = try? Data(contentsOf: file) {
            if let root = try? JSONValue.fastParse(data), root.value(at: "components.schemas") != nil {
                // A read is a use: the disk cache evicts the least recently used file first.
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
                return Loaded(document: LoadedSchemaDocument(components: root), downloaded: false)
            }
            try? FileManager.default.removeItem(at: file)   // unreadable: fetch it again
        }
        guard let data = try? await fetch(url), let raw = try? JSONValue.fastParse(data),
              let schemas = raw.value(at: "components.schemas") else { return nil }
        let trimmed: JSONValue = ["components": ["schemas": schemas]]
        if let file, let directory, let bytes = try? trimmed.data() {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? bytes.write(to: file, options: .atomic)
        }
        return Loaded(document: LoadedSchemaDocument(components: trimmed), downloaded: true)
    }

    /// Removes the least recently modified files until the cache fits `maxBytes`.
    static func pruneDisk(root: URL?, maxBytes: Int) {
        guard let root, let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var files: [(url: URL, size: Int, date: Date)] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            if let size = values?.fileSize { files.append((url, size, values?.contentModificationDate ?? .distantPast)) }
        }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files.sorted(by: { $0.date < $1.date }) where total > maxBytes {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    /// A fixed-length, file-name safe name for any text: the first 16 hex digits of its SHA-256.
    static func digest(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Bundled

    private func bundledSchema(_ gvk: GroupVersionKind, gv: String) -> KindSchema? {
        guard let minor = bundled.nearestMinor(to: serverVersion) else { return nil }
        let key = "bundled:\(minor):\(gv)"
        if cache.value(for: key) == nil {
            guard let docs = bundled.load(minor: minor) else { return nil }
            for (path, doc) in docs { cache.insert(doc, for: "bundled:\(minor):\(path)") }
        }
        guard let doc = cache.value(for: key), let schema = doc.schema(for: gvk) else { return nil }
        lastSource = .bundled(minor: minor)
        return KindSchema(document: doc.document, schema: schema, source: .bundled(minor: minor))
    }
}
