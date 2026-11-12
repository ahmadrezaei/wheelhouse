#if os(macOS)
import Foundation
import Security
import WheelhouseKit

public enum SessionKubeconfigError: Error, Equatable, LocalizedError {
    case invalidClusterID
    case unsafeDirectory(String)
    case writeFailed(String)
    public var errorDescription: String? {
        switch self {
        case .invalidClusterID: "The cluster ID can't be used in a session address."
        case .unsafeDirectory(let why): "The session folder is not safe: \(why)"
        case .writeFailed(let why): "The session kubeconfig could not be written: \(why)"
        }
    }
}

/// Writes the per-session kubeconfig (ARCHITECTURE-MAC section 3.6): under `AppPaths.sessions/<uuid>/kubeconfig`, never `~/.kube`.
/// The folder is 0700 and the file 0400, created with `O_EXCL|O_NOFOLLOW` at that mode (no umask window), renamed into place, and
/// hashed. The file is JSON, which kubectl and helm read as YAML, so display names can't break its syntax.
public struct SessionKubeconfigWriter: Sendable {
    public let paths: AppPaths
    public init(paths: AppPaths) { self.paths = paths }

    public struct Written: Sendable, Equatable {
        public var file: URL
        public var directory: URL
        public var hash: String
    }

    /// A cluster ID is a path segment of the proxy address: letters, digits and `._-` only.
    public static func isValid(clusterID: ClusterID) -> Bool {
        !clusterID.isEmpty && clusterID.count <= 128 && clusterID != "." && clusterID != ".."
            && clusterID.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D }
    }

    /// kubeconfig wants the base64 of a PEM text.
    static func pemBase64(_ der: Data) -> String {
        let body = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return Data("-----BEGIN CERTIFICATE-----\n\(body)\n-----END CERTIFICATE-----\n".utf8).base64EncodedString()
    }

    public static func contents(port: UInt16, clusterID: ClusterID, clusterName: String, token: String, namespace: String?, certificateDER: Data) throws -> Data {
        guard isValid(clusterID: clusterID) else { throw SessionKubeconfigError.invalidClusterID }
        let short = "wh-" + String(clusterID.prefix(8))
        var context: [String: Any] = ["cluster": short, "user": "wh-session"]
        if let namespace, !namespace.isEmpty { context["namespace"] = namespace }
        let config: [String: Any] = [
            "apiVersion": "v1",
            "kind": "Config",
            "clusters": [["name": short, "cluster": ["server": "https://127.0.0.1:\(port)/c/\(clusterID)", "certificate-authority-data": pemBase64(certificateDER)]]],
            "users": [["name": "wh-session", "user": ["token": token]]],
            "contexts": [["name": clusterName, "context": context]],
            "current-context": clusterName,
        ]
        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    public func write(sessionID: UUID, port: UInt16, clusterID: ClusterID, clusterName: String, token: String, namespace: String?, certificateDER: Data) throws -> Written {
        let data = try Self.contents(port: port, clusterID: clusterID, clusterName: clusterName, token: token, namespace: namespace, certificateDER: certificateDER)
        let directory = paths.sessions.appending(path: sessionID.uuidString.lowercased(), directoryHint: .isDirectory)
        // Parents (…/wheelhouse[-debug]/sessions) are created 0700 too.
        let parent = paths.sessions
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw SessionKubeconfigError.writeFailed("mkdir: \(String(cString: strerror(errno)))") }
        try Self.checkDirectory(directory)
        let final = directory.appending(path: "kubeconfig")
        let temp = directory.appending(path: ".kubeconfig.\(UUID().uuidString.prefix(8))")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o400)
        guard fd >= 0 else { throw SessionKubeconfigError.writeFailed("open: \(String(cString: strerror(errno)))") }
        var offset = 0
        let ok: Bool = data.withUnsafeBytes { raw in
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return fsync(fd) == 0
        }
        close(fd)
        guard ok else {
            unlink(temp.path)
            throw SessionKubeconfigError.writeFailed("write failed")
        }
        guard rename(temp.path, final.path) == 0 else {
            let why = String(cString: strerror(errno))
            unlink(temp.path)
            throw SessionKubeconfigError.writeFailed("rename: \(why)")
        }
        return Written(file: final, directory: directory, hash: Hashing.sha256Hex(data))
    }

    private static func checkDirectory(_ directory: URL) throws {
        var st = stat()
        guard lstat(directory.path, &st) == 0 else { throw SessionKubeconfigError.unsafeDirectory("missing") }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw SessionKubeconfigError.unsafeDirectory("not a directory or a symlink") }
        guard st.st_uid == getuid() else { throw SessionKubeconfigError.unsafeDirectory("not owned by this user") }
        guard (st.st_mode & 0o777) == 0o700 else { throw SessionKubeconfigError.unsafeDirectory("mode is not 0700") }
    }

    public enum Integrity: Equatable, Sendable {
        case intact
        case missing
        case modeChanged
        case replaced
        case contentChanged
    }

    /// Whether the file is still exactly what was written: a regular file owned by this user, mode 0400, same hash. A changed file
    /// turns the terminal banner Unguarded and ends the session (M5b).
    public static func verify(file: URL, hash: String) -> Integrity {
        var st = stat()
        guard lstat(file.path, &st) == 0 else { return .missing }
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else { return .replaced }
        guard (st.st_mode & 0o777) == 0o400 else { return .modeChanged }
        guard let data = try? Data(contentsOf: file), Hashing.sha256Hex(data) == hash else { return .contentChanged }
        return .intact
    }

    /// Removes the file and its folder.
    public static func remove(directory: URL) {
        let file = directory.appending(path: "kubeconfig")
        chmod(directory.path, 0o700)
        unlink(file.path)
        // The terminal puts its shell-integration files in the same folder; removeItem unlinks symlinks without following them.
        try? FileManager.default.removeItem(at: directory)
    }
}
#endif
