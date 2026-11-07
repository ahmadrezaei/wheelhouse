#if os(macOS)
import Foundation
import Synchronization
import WheelhouseKit

extension AppPaths {
    /// Settings → Moorings choices (sources, first-run flag).
    public var mooringsPreferencesFile: URL { root.appending(path: "moorings.json") }
}

/// Atomic, owner-only JSON persistence.
enum JSONFile {
    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let tmp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: [.atomic])
        _ = chmod(tmp.path, 0o600)
        if rename(tmp.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

/// The Mac-local overlay for discovered clusters: user overrides (name, environment, read-only, colour, namespaces, hidden) keyed by
/// `ClusterID`, in `discovered-clusters.json`. Discovered clusters never reach the iCloud mirror.
public final class DiscoveredClusterStore: Sendable {
    struct File: Codable {
        var version = 1
        var clusters: [ClusterID: DiscoveredOverride] = [:]
    }
    private let fileURL: URL
    private let state: Mutex<File>
    /// Overrides are kept this long after their context disappeared.
    public static let retention: TimeInterval = 30 * 86_400

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.state = Mutex(JSONFile.read(File.self, from: fileURL) ?? File())
    }

    public func override(for id: ClusterID) -> DiscoveredOverride? { state.withLock { $0.clusters[id] } }
    public var all: [ClusterID: DiscoveredOverride] { state.withLock { $0.clusters } }

    public func set(_ value: DiscoveredOverride?, for id: ClusterID) throws {
        let file = state.withLock { s -> File in s.clusters[id] = value; return s }
        try JSONFile.write(file, to: fileURL)
    }

    public func update(_ id: ClusterID, _ change: (inout DiscoveredOverride) -> Void) throws {
        let file = state.withLock { s -> File in
            var o = s.clusters[id] ?? DiscoveredOverride()
            change(&o)
            s.clusters[id] = o
            return s
        }
        try JSONFile.write(file, to: fileURL)
    }

    /// Replaces many overrides in one write.
    public func apply(_ changes: [ClusterID: DiscoveredOverride?]) throws {
        let file = state.withLock { s -> File in
            for (id, value) in changes { s.clusters[id] = value }
            return s
        }
        try JSONFile.write(file, to: fileURL)
    }

    /// Drops overrides of contexts that have been gone for longer than the retention period.
    public func sweep(now: Date = Date()) throws {
        let (file, changed) = state.withLock { s -> (File, Bool) in
            let before = s.clusters.count
            s.clusters = s.clusters.filter { _, o in o.sourceRemovedAt.map { now.timeIntervalSince($0) < Self.retention } ?? true }
            return (s, s.clusters.count != before)
        }
        if changed { try JSONFile.write(file, to: fileURL) }
    }
}

/// `MooringsPreferences` on disk.
public final class MooringsPreferencesStore: Sendable {
    private let fileURL: URL
    private let state: Mutex<MooringsPreferences>

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.state = Mutex(JSONFile.read(MooringsPreferences.self, from: fileURL) ?? MooringsPreferences())
    }

    public var value: MooringsPreferences { state.withLock { $0 } }

    public func update(_ change: (inout MooringsPreferences) -> Void) throws {
        let v = state.withLock { s -> MooringsPreferences in change(&s); return s }
        try JSONFile.write(v, to: fileURL)
    }
}
#endif
