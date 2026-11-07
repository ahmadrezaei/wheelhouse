import Foundation
import Yams

/// Where helm keeps its repository configuration and index caches.
public struct HelmPaths: Sendable, Hashable {
    public var repositoryConfig: URL
    public var repositoryCache: URL

    public init(repositoryConfig: URL, repositoryCache: URL) {
        self.repositoryConfig = repositoryConfig
        self.repositoryCache = repositoryCache
    }

    /// Helm's own resolution (`helm env`): explicit `HELM_REPOSITORY_*`, then `HELM_CONFIG_HOME` / `HELM_CACHE_HOME`, then XDG, then
    /// the macOS defaults (`~/Library/Preferences/helm`, `~/Library/Caches/helm`). `environment` is the process environment with
    /// any isolation overrides (the Mac app's isolated `HELM_*` while the safety gate is on) merged over it by the caller.
    public static func resolve(environment: [String: String], home: URL) -> HelmPaths {
        func url(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        let config: URL
        if let explicit = environment["HELM_REPOSITORY_CONFIG"], !explicit.isEmpty { config = url(explicit) }
        else if let home = environment["HELM_CONFIG_HOME"], !home.isEmpty { config = url(home).appending(path: "repositories.yaml") }
        else if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty { config = url(xdg).appending(path: "helm/repositories.yaml") }
        else { config = home.appending(path: "Library/Preferences/helm/repositories.yaml") }

        let cache: URL
        if let explicit = environment["HELM_REPOSITORY_CACHE"], !explicit.isEmpty { cache = url(explicit) }
        else if let c = environment["HELM_CACHE_HOME"], !c.isEmpty { cache = url(c).appending(path: "repository", directoryHint: .isDirectory) }
        else if let xdg = environment["XDG_CACHE_HOME"], !xdg.isEmpty { cache = url(xdg).appending(path: "helm/repository", directoryHint: .isDirectory) }
        else { cache = home.appending(path: "Library/Caches/helm/repository", directoryHint: .isDirectory) }
        return HelmPaths(repositoryConfig: config, repositoryCache: cache)
    }
}

/// One repository of `repositories.yaml`. Credentials are deliberately not read.
public struct HelmRepository: Sendable, Hashable, Identifiable {
    public var name: String
    public var url: String
    public var hasCredentials: Bool
    public var isOCI: Bool { url.hasPrefix("oci://") }
    public var id: String { name }

    /// Name of helm's cached index file, `<name>-index.yaml`.
    public var indexFileName: String { "\(name)-index.yaml" }
}

public struct HelmChartVersion: Sendable, Hashable, Codable {
    public var version: String
    public var appVersion: String?
    public var created: String?
    public var deprecated: Bool
}

/// A chart as the Charts section shows it: the newest version's facts plus every version.
public struct HelmChartSummary: Sendable, Hashable, Codable, Identifiable {
    public var repository: String
    public var name: String
    public var latest: HelmChartVersion
    public var versions: [HelmChartVersion]
    public var description: String?
    public var icon: String?
    public var home: String?
    public var keywords: [String]
    public var maintainers: [String]
    public var id: String { "\(repository)/\(name)" }
}

/// A parsed repository index in compact form.
public struct HelmRepositoryIndex: Sendable, Hashable, Codable {
    public var repository: String
    public var generated: String?
    public var charts: [HelmChartSummary]
    /// Size and modification time of the source file this was built from.
    public var sourceSize: Int
    public var sourceModified: TimeInterval
}

public enum HelmRepositoryError: Error, Equatable, Sendable {
    case unreadable(String)
    case notAnIndex
}

public enum HelmRepositories {
    /// Parses `repositories.yaml`. A missing file means no repositories.
    public static func load(config: URL) throws -> [HelmRepository] {
        guard FileManager.default.fileExists(atPath: config.path) else { return [] }
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { throw HelmRepositoryError.unreadable(config.lastPathComponent) }
        return try parse(text)
    }

    public static func parse(_ yaml: String) throws -> [HelmRepository] {
        guard let root = try? YAMLCodec.parse(yaml) else { throw HelmRepositoryError.unreadable("repositories.yaml") }
        return (root["repositories"]?.arrayValue ?? []).compactMap { r in
            guard let name = r["name"]?.stringValue, let url = r["url"]?.stringValue else { return nil }
            let hasCredentials = !(r["username"]?.stringValue ?? "").isEmpty || !(r["password"]?.stringValue ?? "").isEmpty
            return HelmRepository(name: name, url: url, hasCredentials: hasCredentials)
        }
    }

    /// Modification time of helm's cached index, if the repository was ever updated.
    public static func lastUpdated(_ repository: HelmRepository, cache: URL) -> Date? {
        let file = cache.appending(path: repository.indexFileName)
        return (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    /// Parses a cached `<repo>-index.yaml` into the compact form. Large indexes (tens of MB) should be parsed once per file
    /// modification on a utility queue: use ``HelmIndexStore``.
    public static func parseIndex(_ data: Data, repository: String, sourceSize: Int = 0, sourceModified: TimeInterval = 0) throws -> HelmRepositoryIndex {
        guard let text = String(data: data, encoding: .utf8), let root = try? Yams.compose(yaml: text), case .mapping(let top) = root else {
            throw HelmRepositoryError.notAnIndex
        }
        func scalar(_ node: Yams.Node?) -> String? { node?.scalar?.string }
        func string(_ mapping: Yams.Node.Mapping, _ key: String) -> String? {
            let value = mapping[key]
            return value?.scalar?.string
        }
        guard case .mapping(let entries)? = top["entries"] else {
            if top["apiVersion"] == nil { throw HelmRepositoryError.notAnIndex }
            return HelmRepositoryIndex(repository: repository, generated: scalar(top["generated"]), charts: [], sourceSize: sourceSize, sourceModified: sourceModified)
        }
        var charts: [HelmChartSummary] = []
        for (nameNode, versionsNode) in entries {
            guard let name = nameNode.scalar?.string, case .sequence(let sequence) = versionsNode else { continue }
            var versions: [HelmChartVersion] = []
            var newest: Yams.Node.Mapping?
            for node in sequence {
                guard case .mapping(let m) = node, let version = string(m, "version") else { continue }
                versions.append(HelmChartVersion(version: version, appVersion: string(m, "appVersion"), created: string(m, "created"),
                                                 deprecated: string(m, "deprecated") == "true"))
                if newest == nil { newest = m }          // helm writes versions newest first
            }
            guard let first = newest, let latest = versions.first else { continue }
            charts.append(HelmChartSummary(
                repository: repository, name: name, latest: latest, versions: versions,
                description: string(first, "description"), icon: string(first, "icon"), home: string(first, "home"),
                keywords: { if case .sequence(let s)? = first["keywords"] { return s.compactMap { $0.scalar?.string } } else { return [] } }(),
                maintainers: { if case .sequence(let s)? = first["maintainers"] { return s.compactMap { n -> String? in
                    if case .mapping(let m) = n { return string(m, "name") } else { return nil } } } else { return [] } }()))
        }
        charts.sort { $0.name < $1.name }
        return HelmRepositoryIndex(repository: repository, generated: scalar(top["generated"]), charts: charts, sourceSize: sourceSize, sourceModified: sourceModified)
    }

    /// Case-insensitive search over name, description and keywords; name matches first.
    public static func search(_ query: String, in charts: [HelmChartSummary]) -> [HelmChartSummary] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return charts }
        func score(_ c: HelmChartSummary) -> Int? {
            let name = c.name.lowercased()
            if name == q { return 0 }
            if name.hasPrefix(q) { return 1 }
            if name.contains(q) { return 2 }
            if c.keywords.contains(where: { $0.lowercased().contains(q) }) { return 3 }
            if (c.description ?? "").lowercased().contains(q) { return 4 }
            return nil
        }
        return charts.compactMap { c in score(c).map { (c, $0) } }.sorted { ($0.1, $0.0.name) < ($1.1, $1.0.name) }.map(\.0)
    }
}

/// Parses repository indexes once per file modification and keeps the compact result on disk
/// (`<directory>/<repo>.json`), so a 30 MB `index.yaml` is not parsed again until `helm repo update` rewrites it.
public struct HelmIndexStore: Sendable {
    public var cacheDirectory: URL

    public init(cacheDirectory: URL) { self.cacheDirectory = cacheDirectory }

    /// Reads or builds the compact index for a repository. Blocking: call it off the main actor.
    public func index(for repository: HelmRepository, helmCache: URL) throws -> HelmRepositoryIndex? {
        let source = helmCache.appending(path: repository.indexFileName)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.path) else { return nil }   // never updated
        let size = (attributes[.size] as? Int) ?? 0
        let modified = ((attributes[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970
        let compact = cacheDirectory.appending(path: "\(repository.name.replacingOccurrences(of: "/", with: "_")).json")
        if let data = try? Data(contentsOf: compact), let cached = try? JSONDecoder().decode(HelmRepositoryIndex.self, from: data),
           cached.sourceSize == size, cached.sourceModified == modified {
            return cached
        }
        guard let raw = try? Data(contentsOf: source, options: .mappedIfSafe) else { throw HelmRepositoryError.unreadable(source.lastPathComponent) }
        let parsed = try HelmRepositories.parseIndex(raw, repository: repository.name, sourceSize: size, sourceModified: modified)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        if let encoded = try? JSONEncoder().encode(parsed) { try? encoded.write(to: compact, options: .atomic) }
        return parsed
    }
}

/// Everything the Charts and Repositories sections show, read from helm's own configuration and caches.
public struct HelmRepositorySnapshot: Sendable {
    public var repositories: [HelmRepository]
    /// Compact indexes of the repositories that were updated at least once, by repository name.
    public var indexes: [String: HelmRepositoryIndex]
    /// Per-repository failures (an unreadable or malformed index): the row shows the error and Retry.
    public var errors: [String: String]
    public var lastUpdated: [String: Date]
    /// repositories.yaml could not be parsed.
    public var configError: String?
    /// False when helm has never been configured on this machine (no repositories.yaml).
    public var configExists: Bool

    public init(repositories: [HelmRepository] = [], indexes: [String: HelmRepositoryIndex] = [:], errors: [String: String] = [:],
                lastUpdated: [String: Date] = [:], configError: String? = nil, configExists: Bool = false) {
        self.repositories = repositories
        self.indexes = indexes
        self.errors = errors
        self.lastUpdated = lastUpdated
        self.configError = configError
        self.configExists = configExists
    }

    public var charts: [HelmChartSummary] { indexes.values.flatMap(\.charts).sorted { ($0.name, $0.repository) < ($1.name, $1.repository) } }

    /// Reads the config and every index, parsing each index at most once per file modification. Runs off the caller's actor
    /// (a large `index.yaml` takes seconds to parse).
    @concurrent
    public static func load(paths: HelmPaths, indexCache: URL) async -> HelmRepositorySnapshot {
        let exists = FileManager.default.fileExists(atPath: paths.repositoryConfig.path)
        var snapshot = HelmRepositorySnapshot(repositories: [], indexes: [:], errors: [:], lastUpdated: [:], configError: nil, configExists: exists)
        do { snapshot.repositories = try HelmRepositories.load(config: paths.repositoryConfig) }
        catch { snapshot.configError = "repositories.yaml could not be read."; return snapshot }
        let store = HelmIndexStore(cacheDirectory: indexCache)
        for repository in snapshot.repositories where !repository.isOCI {
            if let date = HelmRepositories.lastUpdated(repository, cache: paths.repositoryCache) { snapshot.lastUpdated[repository.name] = date }
            do {
                if let index = try store.index(for: repository, helmCache: paths.repositoryCache) { snapshot.indexes[repository.name] = index }
            } catch {
                snapshot.errors[repository.name] = "The cached index could not be read. Run helm repo update."
            }
        }
        return snapshot
    }
}

/// What a pulled chart archive holds that the detail pane shows. Charts are read natively: gzip, then tar.
public struct HelmChartArchive: Sendable, Hashable {
    public var chartYAML: String?
    public var values: String?
    public var schema: String?
    public var readme: String?

    /// `chartName` is the top-level directory inside the archive.
    public static func read(tgz: Data) throws -> HelmChartArchive {
        let wanted: Set<String> = ["chart.yaml", "values.yaml", "values.schema.json", "readme.md"]
        let entries = try TarReader.entries(inGzip: tgz, limit: 128 * 1024 * 1024) { path in
            let parts = path.split(separator: "/")
            return parts.count == 2 && wanted.contains(parts[1].lowercased())     // only the chart's own top-level files
        }
        func text(_ file: String) -> String? {
            entries.first { $0.path.split(separator: "/").last?.lowercased() == file }.flatMap { String(data: $0.data, encoding: .utf8) }
        }
        return HelmChartArchive(chartYAML: text("chart.yaml"), values: text("values.yaml"), schema: text("values.schema.json"), readme: text("readme.md"))
    }

    /// `helm install` caches the archive it pulled in the repository cache as `<chart>-<version>.tgz`.
    public static func cachedArchive(chart: String, version: String, cache: URL) -> URL? {
        let url = cache.appending(path: "\(chart)-\(version).tgz")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
