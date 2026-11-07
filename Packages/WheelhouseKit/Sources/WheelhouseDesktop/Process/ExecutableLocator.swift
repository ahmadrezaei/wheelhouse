#if os(macOS)
import Darwin
import Foundation

/// Finds a program by name (ARCHITECTURE-MAC §3.1): the shell snapshot's PATH first, then the fallback directories. The result is
/// always an absolute path to a regular file the user may execute; a bare name is never handed to `posix_spawn`.
public struct ExecutableLocator: Sendable {
    public var searchPath: [String]
    /// Per-tool overrides from Settings → Advanced (tool name to absolute path).
    public var overrides: [String: String]

    public init(snapshot: ShellSnapshot?, home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true), overrides: [String: String] = [:]) {
        let fromSnapshot = (snapshot?.path ?? "").split(separator: ":").map(String.init)
        let fallback = ShellEnvironment.fallbackPath(home: home).split(separator: ":").map(String.init)
        var seen = Set<String>()
        self.searchPath = (fromSnapshot + fallback).filter { !$0.isEmpty && seen.insert($0).inserted }
        self.overrides = overrides
    }

    public init(searchPath: [String], overrides: [String: String] = [:]) {
        self.searchPath = searchPath
        self.overrides = overrides
    }

    public func find(_ name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        if let o = overrides[name], Self.isExecutableFile(o) { return URL(fileURLWithPath: o) }
        for dir in searchPath {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if Self.isExecutableFile(candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    /// A command from a kubeconfig `exec` stanza: a `/` in it means a path (relative ones resolve against the file's folder),
    /// otherwise the PATH search.
    public func resolve(command: String, baseDirectory: String?) -> URL? {
        if command.contains("/") {
            let path = command.hasPrefix("/") ? command : URL(fileURLWithPath: command, relativeTo: baseDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }).path
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            return Self.isExecutableFile(standardized) ? URL(fileURLWithPath: standardized) : nil
        }
        return find(command)
    }

    /// A regular file (symlinks resolved) with the execute bit for the current user.
    static func isExecutableFile(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }
}
#endif
