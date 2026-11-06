import Foundation

/// Persists non-secret cluster metadata as JSON in the App Group container. Clusters flagged `iCloudSync` are also
/// mirrored into one synchronizable Keychain item and merged back on launch (newest `modifiedAt` wins).
///
/// The mirror also carries *tombstones* (`deleted`): a cluster removed on one device is removed everywhere instead of being
/// resurrected from another device's copy, and `save()` merges with whatever the mirror currently holds so one device never
/// overwrites clusters another device added.
public protocol ClusterMetadataStoring: Sendable {
    func load() -> [ClusterConfig]
    func save(_ clusters: [ClusterConfig]) throws
}

/// Where the cross-device copy lives (iCloud Keychain in production, in memory in tests).
public protocol MetadataMirroring: Sendable {
    func read() -> Data?
    func write(_ data: Data) throws
    func clear() throws
}

struct KeychainMetadataMirror: MetadataMirroring {
    private static let service = "app.wheelhouse.sync"
    private static let account = "clusters"
    var backend: any KeychainBackend = SystemKeychain()
    func read() -> Data? { try? KeychainAccess.read(service: Self.service, account: Self.account, in: backend) }
    func write(_ data: Data) throws { try KeychainAccess.write(data, service: Self.service, account: Self.account, synchronizable: true, in: backend) }
    func clear() throws { try KeychainAccess.delete(service: Self.service, account: Self.account, in: backend) }
}

public final class InMemoryMetadataMirror: MetadataMirroring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    public init() {}
    public func read() -> Data? { lock.withLock { data } }
    public func write(_ data: Data) throws { lock.withLock { self.data = data } }
    public func clear() throws { lock.withLock { data = nil } }
}

public struct ClusterMetadataStore: ClusterMetadataStoring {
    /// The mirror payload. Older builds wrote a bare `[ClusterConfig]` array; that is still readable.
    struct Mirror: Codable, Equatable {
        var clusters: [ClusterConfig] = []
        /// Cluster id -> when it was deleted. A tombstone beats a copy whose `modifiedAt` is older.
        var deleted: [ClusterID: Date] = [:]
    }

    static let tombstoneLifetime: TimeInterval = 90 * 86_400
    /// Mirror entries for clusters that stopped syncing are kept this long so other devices see the change.
    static let unsyncedRetention: TimeInterval = 30 * 86_400

    private let fileURL: URL
    private let mirror: (any MetadataMirroring)?

    public init(directory: URL = AppGroup.containerURL, useKeychainMirror: Bool = true) {
        self.init(directory: directory, mirror: useKeychainMirror ? KeychainMetadataMirror() : nil)
    }

    public init(directory: URL, mirror: (any MetadataMirroring)?) {
        fileURL = directory.appending(path: "clusters.json")
        self.mirror = mirror
    }

    private var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    private var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }

    private func readLocal() -> [ClusterConfig] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([ClusterConfig].self, from: data)) ?? []
    }

    private func readMirror() -> Mirror {
        guard let mirror, let data = mirror.read() else { return Mirror() }
        if let payload = try? decoder.decode(Mirror.self, from: data) { return payload }
        if let legacy = try? decoder.decode([ClusterConfig].self, from: data) { return Mirror(clusters: legacy) }
        return Mirror()
    }

    public func load() -> [ClusterConfig] {
        let local = readLocal()
        guard mirror != nil else { return local }
        let remote = readMirror()
        return Self.applying(tombstones: remote.deleted, to: Self.merge(local: local, mirrored: remote.clusters))
    }

    public func save(_ clusters: [ClusterConfig]) throws {
        let persistent = clusters.filter { !$0.isDemo }
        let previous = readLocal()
        try encoder.encode(persistent).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        guard let mirror else { return }

        let now = Date()
        var merged = readMirror()
        merged.deleted = merged.deleted.filter { now.timeIntervalSince($0.value) < Self.tombstoneLifetime }

        // Deletions made on this device: a synced cluster that is gone from the list gets a tombstone.
        let currentIDs = Set(persistent.map(\.id))
        for old in previous where old.iCloudSync && !currentIDs.contains(old.id) { merged.deleted[old.id] = now }

        // Upsert this device's synced clusters (and clusters that just stopped syncing, so other devices learn it) on top of
        // whatever the mirror holds. Clusters other devices added are kept.
        var byID = Dictionary(merged.clusters.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.modifiedAt >= b.modifiedAt ? a : b })
        for c in persistent where c.iCloudSync || byID[c.id] != nil {
            if let existing = byID[c.id], existing.modifiedAt > c.modifiedAt { continue }
            byID[c.id] = c
        }
        // Re-adding a cluster after deleting it (newer modifiedAt) revives it; otherwise the tombstone wins.
        for c in persistent { if let t = merged.deleted[c.id], c.modifiedAt > t { merged.deleted[c.id] = nil } }
        merged.clusters = Self.applying(tombstones: merged.deleted, to: Array(byID.values))
            .filter { $0.iCloudSync || now.timeIntervalSince($0.modifiedAt) < Self.unsyncedRetention }
            .sorted { $0.createdAt < $1.createdAt }

        if merged.clusters.isEmpty && merged.deleted.isEmpty {
            try mirror.clear()
        } else {
            try mirror.write(try encoder.encode(merged))
        }
    }

    /// Union by id; for duplicates the newer `modifiedAt` wins. Local order is preserved, new remote clusters are appended.
    static func merge(local: [ClusterConfig], mirrored: [ClusterConfig]) -> [ClusterConfig] {
        var result = local
        for remote in mirrored {
            if let i = result.firstIndex(where: { $0.id == remote.id }) {
                if remote.modifiedAt > result[i].modifiedAt { result[i] = remote }
            } else {
                result.append(remote)
            }
        }
        return result
    }

    /// Drops clusters whose tombstone is newer than their last modification.
    static func applying(tombstones: [ClusterID: Date], to clusters: [ClusterConfig]) -> [ClusterConfig] {
        guard !tombstones.isEmpty else { return clusters }
        return clusters.filter { c in tombstones[c.id].map { c.modifiedAt > $0 } ?? true }
    }
}

public final class InMemoryMetadataStore: ClusterMetadataStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ClusterConfig]
    public init(_ items: [ClusterConfig] = []) { self.items = items }
    public func load() -> [ClusterConfig] { lock.withLock { items } }
    public func save(_ clusters: [ClusterConfig]) throws { lock.withLock { items = clusters.filter { !$0.isDemo } } }
}
