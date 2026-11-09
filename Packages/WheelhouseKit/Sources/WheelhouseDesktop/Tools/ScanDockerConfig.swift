#if os(macOS)
import Darwin
import Foundation

/// The per-scan `DOCKER_CONFIG` directory of the opt-in "Use the cluster's imagePullSecrets" (ARCHITECTURE-MAC §6.1 (c)): mode 0700,
/// a `config.json` of 0600 holding only the matching registry's `auths`, and removed when the scan ends, whatever way it ends
/// (success, failure, cancellation). Never persisted. A crash or kill leaves the folder behind, so ``sweepStale(in:)`` removes any
/// left over the first time the scan queue is used.
public enum ScanDockerConfig {
    public static let prefix = "scan-"

    public static func with<T: Sendable>(config: Data, in sessions: URL, _ body: @Sendable (URL) async throws -> T) async throws -> T {
        let fm = FileManager.default
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dir = sessions.appending(path: prefix + UUID().uuidString, directoryHint: .isDirectory)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appending(path: "config.json")
        guard fm.createFile(atPath: file.path, contents: config, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try await body(dir)
    }

    /// Removes every `scan-*` folder under `sessions`.
    @discardableResult
    public static func sweepStale(in sessions: URL) -> Int {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: sessions.path)) ?? []
        var removed = 0
        for name in names where name.hasPrefix(prefix) {
            if (try? fm.removeItem(at: sessions.appending(path: name))) != nil { removed += 1 }
        }
        return removed
    }
}
#endif
