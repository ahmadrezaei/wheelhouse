import Foundation

/// An LRU cache of parsed schema documents with a byte budget (ARCHITECTURE-MAC section 12.3: schema cache in memory at most 32 MB).
///
/// The budget covers memory the cache owns. A validation pass that still holds a document the cache has evicted keeps it alive
/// until the pass ends. A single document larger than the whole budget is never stored (the caller still uses it once).
struct SchemaMemoryCache: Sendable {
    static let defaultLimit = 32 * 1024 * 1024

    let limit: Int
    private(set) var totalCost = 0
    private var entries: [String: LoadedSchemaDocument] = [:]
    /// Least recently used first.
    private var order: [String] = []

    init(limit: Int = SchemaMemoryCache.defaultLimit) { self.limit = limit }

    var keys: [String] { order }
    var count: Int { entries.count }

    mutating func value(for key: String) -> LoadedSchemaDocument? {
        guard let hit = entries[key] else { return nil }
        touch(key)
        return hit
    }

    /// Stores `doc`, evicting the least recently used documents until it fits. Returns false when it can never fit.
    @discardableResult
    mutating func insert(_ doc: LoadedSchemaDocument, for key: String) -> Bool {
        remove(key)
        guard doc.cost <= limit else { return false }
        while totalCost + doc.cost > limit, let oldest = order.first { remove(oldest) }
        entries[key] = doc
        order.append(key)
        totalCost += doc.cost
        return true
    }

    mutating func remove(_ key: String) {
        guard let old = entries.removeValue(forKey: key) else { return }
        totalCost -= old.cost
        order.removeAll { $0 == key }
    }

    /// Memory pressure: drop everything.
    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        totalCost = 0
    }

    private mutating func touch(_ key: String) {
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
    }
}

/// One in-memory schema budget shared by every store of an app (ARCHITECTURE-MAC section 12.3: 32 MB in total, not per cluster).
/// Keys are `cluster:<cluster>|<url>` for a cluster's documents and `bundled:<minor>:<group-version>` for the bundled ones.
public final class SharedSchemaCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: SchemaMemoryCache

    public init(limit: Int = 32 * 1024 * 1024) { cache = SchemaMemoryCache(limit: limit) }

    public var totalCost: Int { lock.withLock { cache.totalCost } }
    public var limit: Int { lock.withLock { cache.limit } }
    public var keys: [String] { lock.withLock { cache.keys } }

    func value(for key: String) -> LoadedSchemaDocument? { lock.withLock { cache.value(for: key) } }

    @discardableResult
    func insert(_ doc: LoadedSchemaDocument, for key: String) -> Bool { lock.withLock { cache.insert(doc, for: key) } }

    public func removeAll() { lock.withLock { cache.removeAll() } }

    /// Drops every document whose key starts with `prefix` (one cluster's documents).
    public func remove(prefix: String) {
        lock.withLock { for key in cache.keys where key.hasPrefix(prefix) { cache.remove(key) } }
    }
}
