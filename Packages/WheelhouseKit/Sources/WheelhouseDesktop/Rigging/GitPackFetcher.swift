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

    /// One limit for the files of a pack, here and in ``RiggingPackFolder`` (so a pack the fetcher accepts is never refused by the reader).
    public static let maxEntries = RiggingPackFolder.maxEntries
    public static let maxBytes = RiggingPackFolder.maxTotalBytes
    /// The most the staging folder may hold while git runs (the objects of a shallow clone, before the tree is audited). Git is stopped past it.
    public static let maxStagingBytes = 32 * 1024 * 1024
    /// How often the staging folder is measured while git runs.
    var stagingPoll: Duration = .milliseconds(200)

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
        // An address is plain ASCII: an internationalised host can look like another one.
        guard text.unicodeScalars.allSatisfy(\.isASCII), host.unicodeScalars.allSatisfy({ $0.isASCII && $0 != "%" }) else {
            throw FetchError("The address must be plain ASCII (an internationalised host name can look like another one). Use the punycode form.")
        }
        return text
    }

    public static func validate(ref raw: String?) throws -> String? {
        guard let ref = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty else { return nil }
        guard ref.utf8.count <= 200, !ref.hasPrefix("-"), !ref.contains(".."), !ref.hasSuffix("/"), !ref.hasSuffix(".lock"),
              ref.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "._/-".unicodeScalars.contains($0) }) else {
            throw FetchError("That is not a usable branch, tag or commit.")
        }
        if ref.count >= 7, ref.count < 40, ref.allSatisfy(\.isHexDigit) { throw FetchError("Use the full 40-character commit id (an abbreviated one cannot be fetched).") }
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
        ["-c", "core.hooksPath=/dev/null", "-c", "http.followRedirects=false", "-c", "core.fsmonitor=false", "-c", "protocol.ext.allow=never", "-c", "protocol.file.allow=\(allowLocal ? "always" : "never")",
         "-c", "core.symlinks=false", "-c", "core.protectHFS=true", "-c", "core.protectNTFS=true", "-c", "transfer.fsckObjects=true", "-c", "credential.helper=", "-c", "submodule.recurse=false", "-c", "advice.detachedHead=false"]
    }

    /// Runs git. While it runs, the staging folder is measured and git is stopped when it grows past ``maxStagingBytes``.
    private func git(_ arguments: [String], in directory: URL?, home: URL, timeout: Duration = .seconds(30), limit: Int = 1 << 20) async throws -> ProcessResult {
        let spec = ProcessSpec(executable: git, arguments: Self.options(allowLocal: allowLocal) + arguments, environment: environment(home: home), currentDirectory: directory,
                               timeout: timeout, stdoutLimit: limit, stderrLimit: 8 * 1024)
        let staging = home.deletingLastPathComponent()
        let run = run, poll = stagingPoll
        do {
            return try await withThrowingTaskGroup(of: ProcessResult?.self) { group in
                group.addTask { try await run(spec) }
                group.addTask {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: poll)
                        if Self.size(of: staging) > Self.maxStagingBytes { throw FetchError("The repository is larger than \(Self.maxStagingBytes / 1024 / 1024) MB, which is too big for a pack.") }
                    }
                    return nil
                }
                defer { group.cancelAll() }
                while let next = try await group.next() { if let result = next { return result } }
                throw FetchError("git did not finish.")
            }
        } catch let e as SubprocessError { throw FetchError(e.localizedDescription) }
    }

    /// Bytes of regular files under `directory`, not following links.
    static func size(of directory: URL) -> Int {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []) else { return 0 }
        var total = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            total += values.fileSize ?? 0
        }
        return total
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

        let commit = try await download(url: url, ref: ref, work: work, home: home)
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

    /// A shallow download of one commit: `--depth=1 --single-branch` of the branch or tag (or the default branch), or, for a full commit id,
    /// `fetch --depth=1` of that commit. Blobs over 1 MB are left out where the server supports it (a pack file is far smaller).
    private func download(url: String, ref: String?, work: URL, home: URL) async throws -> String {
        let isCommit = ref.map { $0.count == 40 && $0.allSatisfy(\.isHexDigit) } ?? false
        if isCommit, let ref {
            try fileManagerCreate(work)
            _ = try checked(try await git(["init", "--quiet"], in: work, home: home), "Preparing the download")
            _ = try checked(try await git(["fetch", "--quiet", "--depth=1", "--no-tags", "--no-recurse-submodules", "--filter=blob:limit=1m", "--", url, ref], in: work, home: home, timeout: .seconds(180)), "The download")
            let sha = try checked(try await git(["rev-parse", "--verify", "--quiet", "--end-of-options", "FETCH_HEAD^{commit}"], in: work, home: home), "Resolving the commit").trimmingCharacters(in: .whitespacesAndNewlines)
            guard sha.count == 40, sha.allSatisfy(\.isHexDigit), sha.lowercased() == ref.lowercased() else { throw FetchError("“\(ref)” was not found in that repository.") }
            return sha.lowercased()
        }
        var arguments = ["clone", "--quiet", "--no-checkout", "--no-recurse-submodules", "--depth=1", "--single-branch", "--no-tags", "--filter=blob:limit=1m"]
        if let ref { arguments += ["--branch", ref] }
        arguments += ["--", url, work.path]
        do { _ = try checked(try await git(arguments, in: nil, home: home, timeout: .seconds(180)), "The clone") } catch let error as FetchError where ref != nil && error.message.contains("not found") {
            throw FetchError("“\(ref ?? "")” was not found in that repository.")
        }
        return try await resolve(ref: nil, in: work, home: home)
    }

    private func fileManagerCreate(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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
