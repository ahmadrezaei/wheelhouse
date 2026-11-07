import Foundation

/// Where Helm keeps release records (`HELM_DRIVER`). The SQL driver has no cluster objects and is out of scope.
public enum HelmStorage: String, Sendable, Hashable {
    case secret, configMap

    public var kind: ResourceKind { self == .secret ? .secret : .configMap }
}

/// One stored revision, known from metadata only (labels `name`, `status`, `version`, `modifiedAt`): no payload was read.
public struct HelmRevisionSummary: Sendable, Hashable, Identifiable {
    public var name: String
    public var namespace: String
    public var revision: Int
    public var status: HelmReleaseStatus
    public var modifiedAt: Date?
    public var storage: HelmStorage
    /// The Kubernetes object name, `sh.helm.release.v1.<name>.v<N>`.
    public var objectName: String
    /// Changes whenever Helm rewrites the record (for example when it is marked superseded): part of the decode-cache key.
    public var resourceVersion: String?
    public var labels: [String: String]
    public var annotations: [String: String]
    public var id: String { "\(namespace)/\(objectName)" }

    public init(name: String, namespace: String, revision: Int, status: HelmReleaseStatus, modifiedAt: Date?, storage: HelmStorage,
                objectName: String, resourceVersion: String? = nil, labels: [String: String] = [:], annotations: [String: String] = [:]) {
        self.name = name
        self.namespace = namespace
        self.revision = revision
        self.status = status
        self.modifiedAt = modifiedAt
        self.storage = storage
        self.objectName = objectName
        self.resourceVersion = resourceVersion
        self.labels = labels
        self.annotations = annotations
    }

    public static func objectName(release: String, revision: Int) -> String { "sh.helm.release.v1.\(release).v\(revision)" }

    /// Builds a summary from a record's `ObjectMeta`; nil when it is not a Helm release record.
    public init?(meta: ObjectMeta, storage: HelmStorage) {
        guard meta.labels["owner"] == "helm", let name = meta.labels["name"], let version = meta.labels["version"].flatMap(Int.init) else { return nil }
        self.init(name: name, namespace: meta.namespace ?? "", revision: version, status: HelmReleaseStatus(label: meta.labels["status"]),
                  modifiedAt: meta.labels["modifiedAt"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:)) ?? meta.creationTimestamp,
                  storage: storage, objectName: meta.name, resourceVersion: meta.resourceVersion, labels: meta.labels, annotations: meta.annotations)
    }
}

/// One release in a table row: the current (highest) revision and the history behind it.
public struct HelmReleaseSummary: Sendable, Hashable, Identifiable {
    public var current: HelmRevisionSummary
    /// Every revision, newest first.
    public var history: [HelmRevisionSummary]
    public var id: String { "\(current.namespace)/\(current.name)" }
    public var name: String { current.name }
    public var namespace: String { current.namespace }
}

/// Why the list is not available.
public enum HelmListFailure: Sendable, Hashable {
    /// Neither Secrets nor ConfigMaps can be listed. The UI shows the "need list secrets" state and offers the RBAC rule.
    case forbidden(namespace: String?)
}

public struct HelmReleaseListing: Sendable {
    public var releases: [HelmReleaseSummary]
    public var storage: HelmStorage
    public var failure: HelmListFailure?
    public var revisionCount: Int
}

/// Lists Helm releases from record metadata only (ARCHITECTURE-MAC §5.1).
public enum HelmReleaseCatalog {
    public static let labelSelector = "owner=helm"

    /// - Parameter namespace: nil for every namespace.
    ///
    /// Secrets first; when listing them is forbidden, or they hold nothing, ConfigMaps (`HELM_DRIVER=configmap`). Forbidden for
    /// both (or forbidden for Secrets and nothing in ConfigMaps) is reported as ``HelmListFailure/forbidden(namespace:)``.
    public static func load(client: any KubeClientProtocol, namespace: String?,
                            labelSelector: String = HelmReleaseCatalog.labelSelector) async throws -> HelmReleaseListing {
        var secretsForbidden = false
        do {
            let secrets = try await client.listMetadata(kind: .secret, namespace: namespace, labelSelector: labelSelector, limit: nil)
            let revisions = secrets.items.compactMap { HelmRevisionSummary(meta: $0, storage: .secret) }
            if !revisions.isEmpty { return listing(revisions, storage: .secret) }
        } catch KubeError.forbidden {
            secretsForbidden = true
        }

        var configMapsForbidden = false
        var fromConfigMaps: [HelmRevisionSummary] = []
        do {
            let maps = try await client.listMetadata(kind: .configMap, namespace: namespace, labelSelector: labelSelector, limit: nil)
            fromConfigMaps = maps.items.compactMap { HelmRevisionSummary(meta: $0, storage: .configMap) }
        } catch KubeError.forbidden {
            configMapsForbidden = true
        }
        if !fromConfigMaps.isEmpty { return listing(fromConfigMaps, storage: .configMap) }
        if secretsForbidden {
            return HelmReleaseListing(releases: [], storage: .secret, failure: .forbidden(namespace: namespace), revisionCount: 0)
        }
        _ = configMapsForbidden            // Secrets listed fine and were empty: an empty cluster is not an error
        return HelmReleaseListing(releases: [], storage: .secret, failure: nil, revisionCount: 0)
    }

    /// One release with every revision (the release detail's own load), by the `name` label. nil when it does not exist.
    public static func release(named name: String, namespace: String, client: any KubeClientProtocol) async throws -> HelmReleaseSummary? {
        let listing = try await load(client: client, namespace: namespace, labelSelector: "\(labelSelector),name=\(name)")
        if case .forbidden? = listing.failure {
            throw KubeError.forbidden(verb: "list", resource: "secrets", namespace: namespace, message: "Release storage is not readable in \(namespace).")
        }
        return listing.releases.first { $0.name == name }
    }

    /// Groups revisions by (namespace, name), newest first, and orders the rows: attention first, then by name.
    static func listing(_ revisions: [HelmRevisionSummary], storage: HelmStorage) -> HelmReleaseListing {
        var groups: [String: [HelmRevisionSummary]] = [:]
        for r in revisions { groups["\(r.namespace)/\(r.name)", default: []].append(r) }
        let releases = groups.values.map { group -> HelmReleaseSummary in
            let sorted = group.sorted { $0.revision > $1.revision }
            return HelmReleaseSummary(current: sorted[0], history: sorted)
        }
        return HelmReleaseListing(releases: sortedForDisplay(releases), storage: storage, failure: nil, revisionCount: revisions.count)
    }

    /// Problems first (failed and pending-*), then namespace and name.
    public static func sortedForDisplay(_ releases: [HelmReleaseSummary]) -> [HelmReleaseSummary] {
        releases.sorted {
            if $0.current.status.needsAttention != $1.current.status.needsAttention { return $0.current.status.needsAttention }
            if $0.namespace != $1.namespace { return $0.namespace < $1.namespace }
            return $0.name < $1.name
        }
    }

    /// The Role rule that makes the list work, for "Copy RBAC Rule".
    public static func rbacRule(namespace: String?, storage: HelmStorage = .secret) -> String {
        let scope = namespace.map { "namespace \($0)" } ?? "every namespace (a ClusterRole)"
        return """
        # Lets a subject see Helm releases in \(scope)
        rules:
        - apiGroups: [""]
          resources: ["\(storage == .secret ? "secrets" : "configmaps")"]
          verbs: ["get", "list"]
        """
    }
}

/// Decoded releases, in an `NSCache` with a 32 MB cost limit (ARCHITECTURE-MAC §12.3.2). The cost of a release is its decompressed
/// JSON size. Emptied on memory-pressure warnings.
public final class DecodedReleaseCache: @unchecked Sendable {
    public static let defaultByteLimit = 32 * 1024 * 1024
    public static let shared = DecodedReleaseCache()

    private final class Box { let release: HelmRelease; init(_ r: HelmRelease) { release = r } }
    private let cache = NSCache<NSString, Box>()
    public let byteLimit: Int

    public init(byteLimit: Int = DecodedReleaseCache.defaultByteLimit) {
        self.byteLimit = byteLimit
        cache.totalCostLimit = byteLimit
        cache.name = "wheelhouse.helm.decoded"
    }

    /// The key includes the record's resourceVersion, because Helm rewrites old revisions (status becomes superseded).
    public static func key(cluster: ClusterID, revision: HelmRevisionSummary) -> String {
        "\(cluster)|\(revision.namespace)|\(revision.objectName)|\(revision.resourceVersion ?? "-")"
    }

    public func release(forKey key: String) -> HelmRelease? { cache.object(forKey: key as NSString)?.release }

    public func insert(_ release: HelmRelease, forKey key: String) {
        cache.setObject(Box(release), forKey: key as NSString, cost: max(release.payloadBytes, 1))
    }

    /// Memory-pressure hook.
    public func removeAll() { cache.removeAllObjects() }
}

/// Reads and decodes one revision on demand.
public struct HelmReleaseReader: Sendable {
    public var client: any KubeClientProtocol
    public var cluster: ClusterID
    public var cache: DecodedReleaseCache

    public init(client: any KubeClientProtocol, cluster: ClusterID, cache: DecodedReleaseCache = .shared) {
        self.client = client
        self.cluster = cluster
        self.cache = cache
    }

    public func read(_ revision: HelmRevisionSummary) async throws -> HelmRelease {
        let key = DecodedReleaseCache.key(cluster: cluster, revision: revision)
        if let hit = cache.release(forKey: key) { return hit }
        let object = try await client.getRaw(revision.storage.kind, name: revision.objectName, namespace: revision.namespace)
        var release = revision.storage == .secret ? try HelmReleaseCodec.decodeSecret(object) : try HelmReleaseCodec.decodeConfigMap(object)
        // Records written by hand may lack these.
        if release.namespace.isEmpty { release.namespace = revision.namespace }
        if release.version == 0 { release.version = revision.revision }
        cache.insert(release, forKey: key)
        return release
    }
}
