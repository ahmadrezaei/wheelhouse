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
    /// nil only when nothing is stored. Any other failure (locked keychain, interaction not allowed, ...) must throw: a failed
    /// read is NOT an empty mirror.
    func read() throws -> Data?
    func write(_ data: Data) throws
    func clear() throws
}

struct KeychainMetadataMirror: MetadataMirroring {
    private static let service = "app.wheelhouse.sync"
    private static let account = "clusters"
    var backend: any KeychainBackend = SystemKeychain()
    func read() throws -> Data? { try KeychainAccess.read(service: Self.service, account: Self.account, in: backend) }
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
    /// A mirror element this build could not decode (a newer app added an enum case, changed a field type, ...), kept verbatim.
    struct RawCluster: Equatable {
        let data: Data
        /// Read leniently from the raw JSON; nil when the id (or the date) cannot be read.
        let id: ClusterID?
        let modifiedAt: Date?
        init(data: Data) {
            self.data = data
            id = RawJSON.string("id", in: data)
            modifiedAt = RawJSON.date("modifiedAt", in: data)
        }
    }

    /// The mirror payload, read element by element so one unreadable entry never costs the others.
    ///
    /// Compatibility rules (see ARCHITECTURE.md): everything this build cannot understand is carried along and written back
    /// unchanged: undecodable cluster elements (`rawClusters`), tombstones whose value is not a date (`rawDeleted`) and unknown
    /// top-level keys (`unknownTopLevel`). Older builds wrote a bare `[ClusterConfig]` array; that is still readable.
    struct Mirror: Equatable {
        var clusters: [ClusterConfig] = []
        /// Cluster id -> when it was deleted. A tombstone beats a copy whose `modifiedAt` is older.
        var deleted: [ClusterID: Date] = [:]
        var rawClusters: [RawCluster] = []
        var rawDeleted: [String: Data] = [:]
        var unknownTopLevel: [String: Data] = [:]
        /// The stored bytes are not a mirror this build can parse at all. They are never overwritten.
        var isOpaque = false

        init(clusters: [ClusterConfig] = [], deleted: [ClusterID: Date] = [:]) {
            self.clusters = clusters
            self.deleted = deleted
        }

        static func parse(_ data: Data, decoder: JSONDecoder) -> Mirror {
            var m = Mirror()
            func readClusters(_ elements: [Data]) {
                for e in elements {
                    if let c = try? decoder.decode(ClusterConfig.self, from: e) { m.clusters.append(c) } else { m.rawClusters.append(RawCluster(data: e)) }
                }
            }
            if let members = RawJSON.objectMembers(data) {
                for (key, value) in members {
                    switch key {
                    case "clusters":
                        guard let elements = RawJSON.arrayElements(value) else { return opaque() }
                        readClusters(elements)
                    case "deleted":
                        guard let entries = RawJSON.objectMembers(value) else { return opaque() }
                        for (id, v) in entries {
                            if let d = try? decoder.decode(Date.self, from: v) { m.deleted[id] = d } else { m.rawDeleted[id] = v }
                        }
                    default:
                        m.unknownTopLevel[key] = value
                    }
                }
            } else if let elements = RawJSON.arrayElements(data) {
                readClusters(elements)
            } else {
                return opaque()
            }
            return m
        }

        static func opaque() -> Mirror { var m = Mirror(); m.isOpaque = true; return m }

        var isEmpty: Bool { clusters.isEmpty && deleted.isEmpty && rawClusters.isEmpty && rawDeleted.isEmpty && unknownTopLevel.isEmpty }

        func encoded(with encoder: JSONEncoder) throws -> Data {
            func key(_ k: String) throws -> Data { try encoder.encode(k) }
            var members: [(String, Data)] = unknownTopLevel.sorted { $0.key < $1.key }
            let elements = try clusters.map { try encoder.encode($0) } + rawClusters.map(\.data)
            members.append(("clusters", join(elements, open: "[", close: "]")))
            var tombstones: [(String, Data)] = try deleted.filter { rawDeleted[$0.key] == nil }.sorted { $0.key < $1.key }.map { ($0.key, try encoder.encode($0.value)) }
            tombstones += rawDeleted.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            members.append(("deleted", try join(tombstones.map { try key($0.0) + Data(":".utf8) + $0.1 }, open: "{", close: "}")))
            return try join(members.map { try key($0.0) + Data(":".utf8) + $0.1 }, open: "{", close: "}")
        }

        private func join(_ parts: [Data], open: String, close: String) -> Data {
            var out = Data(open.utf8)
            for (i, p) in parts.enumerated() { if i > 0 { out.append(Data(",".utf8)) }; out.append(p) }
            out.append(Data(close.utf8))
            return out
        }
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
    private var compactEncoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }

    /// Local file contents: decodable clusters, plus the raw elements this build cannot decode (kept on save).
    /// `unparseable` is true when the file exists but is not a JSON array at all.
    private func readLocalFile() -> (clusters: [ClusterConfig], raw: [RawCluster], unparseable: Bool) {
        guard let data = try? Data(contentsOf: fileURL) else { return ([], [], false) }
        guard let elements = RawJSON.arrayElements(data) else { return ([], [], true) }
        var clusters: [ClusterConfig] = [], raw: [RawCluster] = []
        for e in elements {
            if let c = try? decoder.decode(ClusterConfig.self, from: e) { clusters.append(c) } else { raw.append(RawCluster(data: e)) }
        }
        return (clusters, raw, false)
    }

    private func readLocal() -> [ClusterConfig] { readLocalFile().clusters }

    private func readMirror() -> Mirror {
        guard let mirror else { return Mirror() }
        do {
            // An empty Mirror means "item not found" only. A failed read is treated like an unparseable mirror: never replaced.
            guard let data = try mirror.read() else { return Mirror() }
            return Mirror.parse(data, decoder: decoder)
        } catch {
            return Mirror.opaque()
        }
    }

    /// True when a raw (undecodable) mirror element describes `cluster` and is at least as new, or its date cannot be read.
    /// Such a copy is the authority: the older decoded copy is hidden and never tombstoned.
    private static func isShadowed(_ cluster: ClusterConfig, by raw: [RawCluster]) -> Bool {
        raw.contains { r in r.id == cluster.id && (r.modifiedAt.map { $0 >= cluster.modifiedAt } ?? true) }
    }

    public func load() -> [ClusterConfig] {
        let local = readLocal()
        guard mirror != nil else { return local }
        let remote = readMirror()
        let visible = Self.merge(local: local, mirrored: remote.clusters).filter { !Self.isShadowed($0, by: remote.rawClusters) }
        return Self.applying(tombstones: remote.deleted, to: visible)
    }

    public func save(_ clusters: [ClusterConfig]) throws {
        let persistent = clusters.filter { !$0.isDemo }
        let local = readLocalFile()
        let previous = local.clusters
        var merged = readMirror()
        // A local copy hidden by a newer raw mirror copy is not in the registry, so it is not in `persistent`. Keep it in
        // clusters.json anyway: if the raw copy later disappears without a tombstone, this readable copy is visible again.
        // (A cluster the user deletes in the same session that a raw twin appears for is also kept hidden: the newer raw
        // copy belongs to a newer app, so it is neither tombstoned nor shown.)
        let currentIDs = Set(persistent.map(\.id))
        let hidden = merged.isOpaque ? [] : previous.filter { !currentIDs.contains($0.id) && Self.isShadowed($0, by: merged.rawClusters) }
        try writeLocal(persistent + hidden, keeping: local)
        guard let mirror else { return }

        let now = Date()
        // A mirror this build cannot parse at all is never replaced: it may be a format a newer app understands.
        if merged.isOpaque { return }
        merged.deleted = merged.deleted.filter { now.timeIntervalSince($0.value) < Self.tombstoneLifetime }

        // Deletions made on this device: a synced cluster that is gone from the list gets a tombstone. A cluster hidden because a
        // newer raw copy exists was not deleted by the user.
        for old in previous where old.iCloudSync && !currentIDs.contains(old.id) && !Self.isShadowed(old, by: merged.rawClusters) {
            merged.deleted[old.id] = now
        }

        // Merge rule for an id present both raw (undecodable, from another device) and decoded: the copy with the newer
        // `modifiedAt` wins; on a tie, or when the raw copy's date cannot be read, the RAW copy wins (never discard what we
        // cannot understand). Raw elements without a readable id are always kept.
        var rawKept = merged.rawClusters
        var decoded = merged.clusters
        decoded.removeAll { c in Self.isShadowed(c, by: rawKept) }
        // A decoded copy that survived is strictly newer than every raw copy of its id (even with no local copy): drop those.
        let decodedIDs = Set(decoded.map(\.id))
        rawKept.removeAll { r in r.id.map(decodedIDs.contains) ?? false }
        for c in persistent where c.iCloudSync || decoded.contains(where: { $0.id == c.id }) {
            if Self.isShadowed(c, by: rawKept) { continue }
            rawKept.removeAll { $0.id == c.id }     // the local copy is strictly newer than every raw copy of it
        }

        // Upsert this device's synced clusters (and clusters that just stopped syncing, so other devices learn it) on top of
        // whatever the mirror holds. Clusters other devices added are kept.
        var byID = Dictionary(decoded.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.modifiedAt >= b.modifiedAt ? a : b })
        for c in persistent where c.iCloudSync || byID[c.id] != nil {
            if Self.isShadowed(c, by: rawKept) { continue }
            if let existing = byID[c.id], existing.modifiedAt > c.modifiedAt { continue }
            byID[c.id] = c
        }
        // Re-adding a cluster after deleting it (newer modifiedAt) revives it; otherwise the tombstone wins.
        for c in persistent { if let t = merged.deleted[c.id], c.modifiedAt > t { merged.deleted[c.id] = nil } }
        merged.clusters = Self.applying(tombstones: merged.deleted, to: Array(byID.values))
            .filter { $0.iCloudSync || now.timeIntervalSince($0.modifiedAt) < Self.unsyncedRetention }
            .sorted { $0.createdAt < $1.createdAt }
        // Tombstones also remove raw copies they are newer than; raw copies with an unreadable id or date stay.
        merged.rawClusters = rawKept.filter { r in
            guard let id = r.id, let m = r.modifiedAt, let t = merged.deleted[id] else { return true }
            return m > t
        }

        if merged.isEmpty {
            try mirror.clear()
        } else {
            try mirror.write(try merged.encoded(with: compactEncoder))
        }
    }

    /// Writes clusters.json, appending raw local elements this build cannot decode. A file that is not a JSON array at all is
    /// copied aside (`clusters.json.unreadable`, or `clusters.json.unreadable-<epoch>` when one exists) before it is replaced.
    private func writeLocal(_ persistent: [ClusterConfig], keeping local: (clusters: [ClusterConfig], raw: [RawCluster], unparseable: Bool)) throws {
        if local.unparseable {
            // A failed copy aborts the save: the unreadable file is never replaced without a backup.
            var backup = fileURL.appendingPathExtension("unreadable")
            if FileManager.default.fileExists(atPath: backup.path) {
                let epoch = Int(Date().timeIntervalSince1970)
                backup = fileURL.appendingPathExtension("unreadable-\(epoch)")
                var n = 1
                while FileManager.default.fileExists(atPath: backup.path) { backup = fileURL.appendingPathExtension("unreadable-\(epoch)-\(n)"); n += 1 }
            }
            try FileManager.default.copyItem(at: fileURL, to: backup)
        }
        let data: Data
        if local.raw.isEmpty {
            data = try encoder.encode(persistent)
        } else {
            var out = Data("[".utf8)
            // Never write a duplicate id: a raw local element whose id is already written as a decoded cluster is dropped.
            let writtenIDs = Set(persistent.map(\.id))
            let keptRaw = local.raw.filter { r in r.id.map { !writtenIDs.contains($0) } ?? true }
            let parts = try persistent.map { try compactEncoder.encode($0) } + keptRaw.map(\.data)
            for (i, p) in parts.enumerated() { if i > 0 { out.append(Data(",".utf8)) }; out.append(p) }
            out.append(Data("]".utf8))
            data = out
        }
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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
