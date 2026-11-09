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
