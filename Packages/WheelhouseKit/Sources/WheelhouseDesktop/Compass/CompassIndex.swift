#if os(macOS)
import Foundation
import WheelhouseKit

/// One result of an object search.
public struct CompassHit: Sendable, Hashable, Identifiable {
    public var cluster: ClusterID
    public var kind: ResourceKind
    public var name: String
    public var namespace: String?
    public var score: Int
    public var isProblem: Bool
    public var id: String { Self.key(cluster: cluster, kindID: kind.id, namespace: namespace, name: name) }

    /// The key of the problem set and of the frecency record of an object (`obj|` prefixed there).
    public static func key(cluster: ClusterID, kindID: String, namespace: String?, name: String) -> String {
        "\(cluster)|\(kindID)|\(namespace ?? "")|\(name)"
    }
    public var frecencyKey: String { "obj|" + id }
}

/// What the Compass index says about itself, for the footer ("Indexed 18,402 objects in 6 clusters · updated 2 min ago").
public struct CompassIndexStats: Sendable, Equatable {
    public var objects = 0
    public var clusters = 0
    public var bytes = 0
    public var updated: Date?
    public init() {}
}

/// The Compass object index (ARCHITECTURE-MAC section 12.4): name, namespace, labels, owner and kind of the objects of the clusters
/// that opted in, nothing else. Never a field, annotation or value of a Secret (a Secret keeps its name and namespace only). The
/// index is capped at 64 MB by an estimate of its in-memory size; when a refresh pushes it over, the cluster focused least recently
/// is evicted first. Search is a linear scan over folded UTF-8 bytes with a bounded top-K, so 100,000 objects answer in a few ms.
public actor CompassIndex {
    public static let defaultCapBytes = 64 * 1_024 * 1_024
    /// Candidates kept before frecency and "problems first" reorder them.
    static let candidateLimit = 300

    struct Entry: Sendable {
        var name: String
        var nameFolded: [UInt8]
        var namespace: String?
        var namespaceFolded: [UInt8]
        var labelsFolded: [UInt8]       // "k=v,k=v", folded
        var owner: String?

        var bytes: Int { 160 + 96 + nameFolded.count * 2 + namespaceFolded.count * 2 + labelsFolded.count + (owner?.utf8.count ?? 0) }
    }

    private struct Bucket {
        var kinds: [UInt16: [Entry]] = [:]
        var bytes = 0
        var focus: UInt64 = 0
    }

    private var buckets: [ClusterID: Bucket] = [:]
    private var kindTable: [ResourceKind] = []
    private var kindIndex: [String: UInt16] = [:]
    private var staged: [String: [Entry]] = [:]
    private var focusCounter: UInt64 = 0
    private var totalBytes = 0
    private var updated: Date?
    private let capBytes: Int
    private let now: @Sendable () -> Date
    /// Clusters evicted by the cap, for diagnostics and tests.
    public private(set) var evictions = 0

    public init(capBytes: Int = CompassIndex.defaultCapBytes, now: @escaping @Sendable () -> Date = { Date() }) {
        self.capBytes = capBytes
        self.now = now
    }

    public var stats: CompassIndexStats {
        var s = CompassIndexStats()
        s.objects = buckets.values.reduce(0) { $0 + $1.kinds.values.reduce(0) { $0 + $1.count } }
        s.clusters = buckets.count
        s.bytes = totalBytes
        s.updated = updated
        return s
    }

    public var indexedClusters: Set<ClusterID> { Set(buckets.keys) }

    // MARK: Writing

    /// Kinds whose objects keep a name only: a Secret's labels and owner are not read into the index at all.
    static func keepsLabels(_ kind: ResourceKind) -> Bool { !(kind.group.isEmpty && kind.kind == "Secret") }

    private func stagingKey(_ cluster: ClusterID, _ kind: ResourceKind) -> String { "\(cluster)|\(kind.id)" }

    /// Starts a refresh of one kind: pages are staged, and `commit` swaps them in, so a refresh that fails halfway leaves the previous
    /// entries alone.
    public func beginRefresh(cluster: ClusterID, kind: ResourceKind) {
        staged[stagingKey(cluster, kind)] = []
    }

    public func stage(cluster: ClusterID, kind: ResourceKind, items: [CompassMetadataItem]) {
        let key = stagingKey(cluster, kind)
        guard staged[key] != nil else { return }
        let labels = Self.keepsLabels(kind)
        staged[key]?.append(contentsOf: items.map { item in
            Entry(name: item.name, nameFolded: CompassMatcher.fold(item.name), namespace: item.namespace,
                  namespaceFolded: CompassMatcher.fold(item.namespace ?? ""),
                  labelsFolded: labels ? CompassMatcher.fold(item.labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")) : [],
                  owner: labels ? item.ownerName.map { (item.ownerKind.map { "\($0)/" } ?? "") + $0 } : nil)
        })
    }

    public func abortRefresh(cluster: ClusterID, kind: ResourceKind) {
        staged[stagingKey(cluster, kind)] = nil
    }

    public func commit(cluster: ClusterID, kind: ResourceKind) {
        guard let entries = staged.removeValue(forKey: stagingKey(cluster, kind)) else { return }
        let idx = index(of: kind)
        var bucket = buckets[cluster] ?? Bucket()
        let old = bucket.kinds[idx]?.reduce(0) { $0 + $1.bytes } ?? 0
        bucket.kinds[idx] = entries.isEmpty ? nil : entries
        let added = entries.reduce(0) { $0 + $1.bytes }
        bucket.bytes += added - old
        totalBytes += added - old
        if bucket.focus == 0 { focusCounter += 1; bucket.focus = focusCounter }
        buckets[cluster] = bucket.kinds.isEmpty ? nil : bucket
        updated = now()
        enforceCap(keeping: cluster)
    }

    /// Replaces every object of one kind (tests and small refreshes).
    public func replace(cluster: ClusterID, kind: ResourceKind, items: [CompassMetadataItem]) {
        beginRefresh(cluster: cluster, kind: kind)
        stage(cluster: cluster, kind: kind, items: items)
        commit(cluster: cluster, kind: kind)
    }

    private func index(of kind: ResourceKind) -> UInt16 {
        if let i = kindIndex[kind.id] { return i }
        let i = UInt16(kindTable.count)
        kindTable.append(kind)
        kindIndex[kind.id] = i
        return i
    }

    /// The cluster the person is looking at: it is evicted last.
    public func noteFocus(_ cluster: ClusterID) {
        guard buckets[cluster] != nil else { return }
        focusCounter += 1
        buckets[cluster]?.focus = focusCounter
    }

    private func enforceCap(keeping keep: ClusterID) {
        while totalBytes > capBytes, !buckets.isEmpty {
            // The least recently focused cluster goes first; the cluster just written only when nothing else is left.
            let victim = buckets.filter { $0.key != keep }.min { $0.value.focus < $1.value.focus }?.key ?? keep
            drop(cluster: victim)
            evictions += 1
        }
    }

    public func drop(cluster: ClusterID) {
        if let b = buckets.removeValue(forKey: cluster) { totalBytes -= b.bytes }
    }

    /// Memory warning: only the clusters in `keep` (the focused pane's) stay.
    public func keepOnly(_ keep: Set<ClusterID>) {
        for id in buckets.keys where !keep.contains(id) { drop(cluster: id) }
    }

    /// Memory critical, or the indexer stopped for good.
    public func removeAll() {
        buckets = [:]
        staged = [:]
        totalBytes = 0
        updated = nil
    }

    // MARK: Search

    /// Short names Compass understands for kinds beyond the catalogue ones (`hr` HelmRelease, `ks` Kustomization, `app` Argo CD).
    static let extraShortNames: [String: [String]] = [
        "pods": ["po"], "deployments": ["deploy"], "daemonsets": ["ds"], "statefulsets": ["sts"], "replicasets": ["rs"], "cronjobs": ["cj"],
        "jobs": ["job"], "configmaps": ["cm"], "secrets": ["secret"], "services": ["svc"], "ingresses": ["ing"], "persistentvolumeclaims": ["pvc"],
        "persistentvolumes": ["pv"], "nodes": ["no"], "namespaces": ["ns"], "serviceaccounts": ["sa"], "customresourcedefinitions": ["crd"],
        "helmreleases": ["hr"], "kustomizations": ["ks"], "applications": ["app"], "horizontalpodautoscalers": ["hpa"],
    ]

    private func kindIndices(matching term: String) -> Set<UInt16> {
        let t = term.lowercased()
        return Set(kindTable.enumerated().compactMap { i, k in
            (k.plural == t || k.kind.lowercased() == t || Self.extraShortNames[k.plural]?.contains(t) == true) ? UInt16(i) : nil
        })
    }

    /// Objects matching `query`, best first. `clusters` maps a cluster ID to its name (for `@cluster`), `problems` holds the
    /// ``CompassHit/key`` of failing objects, `pinned` those on the Rail (`is:pinned`), `frecency` the per-item bonus.
    public func search(_ query: CompassQuery, limit: Int = 50, clusters: [ClusterID: String] = [:], problems: Set<String> = [],
                       pinned: Set<String> = [], frecency: (@Sendable (String) -> Int)? = nil) -> [CompassHit] {
        var tokens = query.tokens.map(CompassMatcher.fold).filter { !$0.isEmpty }
        // A kind name first narrows the search to that kind: `po crash`, `deploy web`.
        var kindFilter: Set<UInt16>?
        if tokens.count >= 2, let first = query.tokens.first {
            let matched = kindIndices(matching: first)
            if !matched.isEmpty { kindFilter = matched; tokens.removeFirst() }
        }
        let selector = query.labelSelector.map { CompassLabelSelector(String($0.map { $0.isUppercase ? Character($0.lowercased()) : $0 })) }
        if let selector, !selector.isValid { return [] }
        // Metadata carries no image or status: `img:` and every `is:` state but failing and pinned find nothing here.
        if query.image != nil { return [] }
        let wantsFailing = query.states.contains("failing"), wantsPinned = query.states.contains("pinned")
        if query.states.contains(where: { $0 != "failing" && $0 != "pinned" }) { return [] }
        let clusterToken = query.cluster.map(CompassMatcher.fold)
        let namespaceToken = query.namespace.map(CompassMatcher.fold)
        guard !tokens.isEmpty || selector != nil || wantsFailing || wantsPinned || kindFilter != nil || clusterToken != nil || namespaceToken != nil else { return [] }

        var candidates: [(score: Int, cluster: ClusterID, kind: UInt16, entry: Int)] = []
        let cap = Self.candidateLimit * 2
        var floorScore = Int.min
        for (cluster, bucket) in buckets {
            if let clusterToken {
                let name = CompassMatcher.fold(clusters[cluster] ?? cluster)
                if CompassMatcher.score(clusterToken, in: name) == nil { continue }
            }
            for (kind, entries) in bucket.kinds {
                if let kindFilter, !kindFilter.contains(kind) { continue }
                let kindObject = kindTable[Int(kind)]
                entries.withUnsafeBufferPointer { buffer in
                    for i in buffer.indices {
                        if let namespaceToken, buffer[i].namespaceFolded.withUnsafeBufferPointer({ CompassMatcher.score(namespaceToken, in: $0) }) == nil { continue }
                        var total = 0
                        var ok = true
                        for token in tokens {
                            var best = buffer[i].nameFolded.withUnsafeBufferPointer { CompassMatcher.score(token, in: $0) } ?? Int.min
                            if best < CompassMatcher.substring, !buffer[i].namespaceFolded.isEmpty,
                               buffer[i].namespaceFolded.withUnsafeBufferPointer({ CompassMatcher.score(token, in: $0) }) != nil { best = max(best, 350) }
                            if best < 200, !buffer[i].labelsFolded.isEmpty, Self.contains(buffer[i].labelsFolded, token) { best = max(best, 150) }
                            if best == Int.min { ok = false; break }
                            total += best
                        }
                        guard ok else { continue }
                        if let selector {
                            if let pairs = selector.equalities {
                                if !pairs.allSatisfy({ Self.containsPair(buffer[i].labelsFolded, $0) }) { continue }
                            } else if !selector.matches(Self.labels(buffer[i].labelsFolded)) { continue }
                        }
                        if wantsFailing || wantsPinned {
                            let key = CompassHit.key(cluster: cluster, kindID: kindObject.id, namespace: buffer[i].namespace, name: buffer[i].name)
                            if wantsFailing, !problems.contains(key) { continue }
                            if wantsPinned, !pinned.contains(key) { continue }
                        }
                        if total < floorScore { continue }
                        candidates.append((total, cluster, kind, i))
                        if candidates.count >= cap {
                            candidates.sort { $0.score > $1.score }
                            candidates.removeLast(candidates.count - Self.candidateLimit)
                            floorScore = candidates.last?.score ?? Int.min
                        }
                    }
                }
            }
        }
        candidates.sort { $0.score > $1.score }
        var hits: [CompassHit] = candidates.prefix(Self.candidateLimit).map { c in
            let entry = buckets[c.cluster]!.kinds[c.kind]![c.entry]
            let kind = kindTable[Int(c.kind)]
            let key = CompassHit.key(cluster: c.cluster, kindID: kind.id, namespace: entry.namespace, name: entry.name)
            return CompassHit(cluster: c.cluster, kind: kind, name: entry.name, namespace: entry.namespace, score: c.score, isProblem: problems.contains(key))
        }
        // Problems first at an equal score, then frecency: both are bonuses on top of the match score.
        for i in hits.indices {
            if hits[i].isProblem { hits[i].score += 60 }
            if let frecency { hits[i].score += frecency(hits[i].frecencyKey) }
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : ($0.name != $1.name ? $0.name < $1.name : $0.id < $1.id) }
        return Array(hits.prefix(limit))
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        let first = needle[0]
        var i = 0
        let last = haystack.count - needle.count
        while i <= last {
            if haystack[i] == first {
                var j = 1
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    /// `k=v` as a whole label of "a=b,k=v,c=d".
    private static func containsPair(_ labels: [UInt8], _ pair: [UInt8]) -> Bool {
        guard pair.count <= labels.count else { return false }
        var i = 0
        let last = labels.count - pair.count
        while i <= last {
            if labels[i] == pair[0], i == 0 || labels[i - 1] == 44 {
                var j = 1
                while j < pair.count, labels[i + j] == pair[j] { j += 1 }
                if j == pair.count, i + j == labels.count || labels[i + j] == 44 { return true }
            }
            i += 1
        }
        return false
    }

    private static func labels(_ folded: [UInt8]) -> [String: String] {
        var out: [String: String] = [:]
        for pair in String(decoding: folded, as: UTF8.self).split(separator: ",") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            out[String(pair[..<eq])] = String(pair[pair.index(after: eq)...])
        }
        return out
    }
}
#endif
