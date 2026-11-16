#if os(macOS)
import Foundation
import WheelhouseKit

/// Fetches a Rigging pack from a git URL with the user's own `git`, through ``Subprocess`` (ARCHITECTURE-MAC section 11).
///
/// What this guarantees, in the order it happens:
/// - the URL is `https://` with no credentials (or, in tests only, a local path); the ref cannot start with `-`;
/// - every `git` run gets an environment built from nothing (no `HOME` of the user, no global or system config, no prompts, only
///   the `https` transport) and `core.hooksPath=/dev/null`, so no hook of any kind can run;
/// - the clone is `--no-checkout --no-recurse-submodules` into a private staging folder under the app's own `rigging/` folder;
/// - the ref is resolved to one commit, the commit's tree is listed first, and a symlink, a submodule, too many files or too many
///   bytes refuse the pack before any file is written;
/// - only then is that one commit checked out (detached), `.git` is deleted, and the folder is read by ``RiggingPackFolder``;
/// - the result lives at `rigging/<name>@<commit>`. Nothing updates by itself: a newer commit is a new fetch the person asks for.
public struct GitPackFetcher: Sendable {
    public typealias Run = @Sendable (ProcessSpec) async throws -> ProcessResult

    public struct Fetched: Sendable {
        public var directory: URL
        public var commit: String
        public var loaded: LoadedRiggingPack
    }

    public struct FetchError: Error, Equatable, Sendable, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    public static let maxEntries = 2000
    public static let maxBytes = 5 * 1024 * 1024

    public var git: URL
    /// `AppPaths.root/rigging`.
    public var root: URL
    /// Tests only: also allow a local path or `file://` URL (a bare repository in a temporary folder).
    public var allowLocal: Bool
    /// Proxy and certificate variables that a clone over https may need (see `EnvironmentBuilder`).
    public var networkEnvironment: [String: String]
    public var run: Run

    public init(git: URL, root: URL, allowLocal: Bool = false, networkEnvironment: [String: String] = [:], run: @escaping Run = { try await Subprocess.run($0) }) {
        self.git = git
        self.root = root
        self.allowLocal = allowLocal
        self.networkEnvironment = networkEnvironment
        self.run = run
    }

    /// The network variables of `environment` that `git` may use.
    public static func networkVariables(from environment: [String: String]) -> [String: String] {
        environment.filter { EnvironmentBuilder.networkKeys.contains($0.key) }
    }

    // MARK: Validation

    public func validate(url raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 500, !text.hasPrefix("-"),
              !text.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7F || $0.properties.generalCategory == .format }) else {
            throw FetchError("That is not a usable git address.")
        }
        if allowLocal, text.hasPrefix("/") || text.hasPrefix("file://") { return text }
        guard let url = URL(string: text), url.scheme == "https", let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw FetchError("Use an https:// address without a user name, password or token in it.")
        }
        return text
    }

    public static func validate(ref raw: String?) throws -> String? {
        guard let ref = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty else { return nil }
        guard ref.utf8.count <= 200, !ref.hasPrefix("-"), !ref.contains(".."), !ref.hasSuffix("/"), !ref.hasSuffix(".lock"),
              ref.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "._/-".unicodeScalars.contains($0) }) else {
            throw FetchError("That is not a usable branch, tag or commit.")
        }
        return ref
    }

    // MARK: Commands

    /// The environment of every git run: built from nothing.
    func environment(home: URL) -> [String: String] {
        var env = networkEnvironment
        env["PATH"] = "/usr/bin:/bin"
        env["HOME"] = home.path
        env["LC_ALL"] = "C"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = "/usr/bin/false"
        env["GIT_ALLOW_PROTOCOL"] = allowLocal ? "https:file" : "https"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_CEILING_DIRECTORIES"] = home.deletingLastPathComponent().path
        return env
    }

    /// The options in front of every subcommand.
    static func options(allowLocal: Bool) -> [String] {
        ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "protocol.ext.allow=never", "-c", "protocol.file.allow=\(allowLocal ? "always" : "never")",
         "-c", "core.symlinks=false", "-c", "core.protectHFS=true", "-c", "core.protectNTFS=true", "-c", "transfer.fsckObjects=true", "-c", "credential.helper=", "-c", "submodule.recurse=false", "-c", "advice.detachedHead=false"]
    }

    private func git(_ arguments: [String], in directory: URL?, home: URL, timeout: Duration = .seconds(30), limit: Int = 1 << 20) async throws -> ProcessResult {
        let spec = ProcessSpec(executable: git, arguments: Self.options(allowLocal: allowLocal) + arguments, environment: environment(home: home), currentDirectory: directory,
                               timeout: timeout, stdoutLimit: limit, stderrLimit: 8 * 1024)
        do { return try await run(spec) } catch let e as SubprocessError { throw FetchError(e.localizedDescription) }
    }

    private func checked(_ result: ProcessResult, _ what: String) throws -> String {
        guard result.exit.succeeded else {
            let detail = String(String.UnicodeScalarView(result.stderrString.unicodeScalars.filter { !RiggingTemplate.isUnsafe($0) }.prefix(300)))
            throw FetchError("\(what) failed" + (detail.isEmpty ? "." : ": \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"))
        }
        return result.stdoutString
    }

    // MARK: Fetch

    /// Clones `url`, resolves `ref` (default: the remote's default branch) to one commit and installs it at `rigging/<name>@<commit>`.
    public func fetch(url rawURL: String, ref rawRef: String?) async throws -> Fetched {
        let url = try validate(url: rawURL)
        let ref = try Self.validate(ref: rawRef)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = root.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        let home = staging.appending(path: "home", directoryHint: .isDirectory)
        let work = staging.appending(path: "repo", directoryHint: .isDirectory)
        try fm.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }

        _ = try checked(try await git(["clone", "--quiet", "--no-checkout", "--no-recurse-submodules", "--", url, work.path], in: nil, home: home, timeout: .seconds(180)), "The clone")

        let commit = try await resolve(ref: ref, in: work, home: home)
        try await auditTree(commit: commit, in: work, home: home)
        _ = try checked(try await git(["checkout", "--quiet", "--detach", "--no-recurse-submodules", commit, "--"], in: work, home: home, timeout: .seconds(60)), "The checkout")
        try fm.removeItem(at: work.appending(path: ".git"))

        let loaded: LoadedRiggingPack
        do { loaded = try RiggingPackFolder.load(work) } catch { throw FetchError(error.localizedDescription) }
        let name = loaded.pack.metadata.name
        guard KubeNames.isDNSLabel(name) else { throw FetchError("The pack name is not a valid name.") }
        let final = root.appending(path: "\(name)@\(commit)", directoryHint: .isDirectory)
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: work, to: final)
        return Fetched(directory: final, commit: commit, loaded: loaded)
    }

    private func resolve(ref: String?, in work: URL, home: URL) async throws -> String {
        let candidates = ref.map { [$0, "origin/\($0)", "refs/tags/\($0)"] } ?? ["HEAD"]
        for candidate in candidates {
            let result = try await git(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(candidate)^{commit}"], in: work, home: home)
            let sha = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.exit.succeeded, sha.count == 40, sha.allSatisfy(\.isHexDigit) {
                if let ref, ref.count == 40, ref.allSatisfy(\.isHexDigit), ref.lowercased() != sha.lowercased() { continue }
                return sha.lowercased()
            }
        }
        throw FetchError(ref.map { "“\($0)” was not found in that repository." } ?? "That repository has no commits to use.")
    }

    /// Lists the commit's tree before anything is written: no symlink, no submodule, a bounded size and file count.
    private func auditTree(commit: String, in work: URL, home: URL) async throws {
        let out = try checked(try await git(["ls-tree", "-r", "-l", "-z", "--full-tree", commit], in: work, home: home, limit: 4 << 20), "Reading the pack")
        var count = 0, bytes = 0
        for record in out.split(separator: "\0") {
            count += 1
            guard count <= Self.maxEntries else { throw FetchError("The pack has more than \(Self.maxEntries) files.") }
            guard let tab = record.firstIndex(of: "\t") else { throw FetchError("The pack listing could not be read.") }
            let fields = record[..<tab].split(separator: " ", omittingEmptySubsequences: true)
            let path = String(record[record.index(after: tab)...])
            guard fields.count >= 4 else { throw FetchError("The pack listing could not be read.") }
            if fields[0] == "120000" { throw FetchError("The pack contains a symbolic link (\(path)); packs may not contain links.") }
            if fields[0] == "160000" || fields[1] == "commit" { throw FetchError("The pack contains a submodule (\(path)); submodules are not followed.") }
            if path.split(separator: "/").contains(where: { $0 == ".." || [".git", ".gitmodules"].contains($0.lowercased()) }) { throw FetchError("The pack contains a path that is not allowed (\(path)).") }
            bytes += Int(fields[3]) ?? 0
            guard bytes <= Self.maxBytes else { throw FetchError("The pack is larger than \(Self.maxBytes / 1024 / 1024) MB.") }
        }
    }

    /// Deletes `rigging/<name>@*` folders other than `keep` (after an update, or when a pack is removed with `keep == nil`).
    public func prune(name: String, keep: String?) {
        let fm = FileManager.default
        for entry in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where entry.hasPrefix("\(name)@") && entry != keep {
            try? fm.removeItem(at: root.appending(path: entry))
        }
    }

    /// Removes folders a crashed fetch left behind.
    public func sweepStaging() {
        let fm = FileManager.default
        for entry in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where entry.hasPrefix(".staging-") { try? fm.removeItem(at: root.appending(path: entry)) }
    }
}
#endif
