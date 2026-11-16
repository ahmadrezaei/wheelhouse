#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

/// A bare repository in a temporary folder. Nothing here touches the network or the user's git configuration.
private struct Fixture {
    let base: URL
    let bare: URL
    let root: URL
    static let git = URL(fileURLWithPath: "/usr/bin/git")
    static let pack = """
    apiVersion: rigging.wheelhouse.app/v1
    kind: Pack
    metadata: { name: sample-pack, version: 1.0.0 }
    views:
      - match: { group: example.io, kind: Widget }
        columns: [ { name: Phase, path: ".status.phase" } ]
    """

    init() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appending(path: "wh-rigging-\(UUID().uuidString)", directoryHint: .isDirectory)
        bare = base.appending(path: "origin.git", directoryHint: .isDirectory)
        root = base.appending(path: "rigging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }

    static let env = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
                      "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com", "HOME": "/nonexistent"]

    @discardableResult
    func git(_ args: [String], in dir: URL? = nil) async throws -> String {
        let r = try await Subprocess.run(ProcessSpec(executable: Self.git, arguments: args, environment: Self.env, currentDirectory: dir, timeout: .seconds(30)))
        #expect(r.exit.succeeded, "git \(args) failed: \(r.stderrString)")
        return r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds a work repository with the given commits (each a list of files), then a bare clone of it. Returns the commit ids.
    func makeRepo(commits: [[String: String]], extra: (URL) async throws -> Void = { _ in }, staged: (URL) async throws -> Void = { _ in }) async throws -> [String] {
        let work = base.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try await git(["init", "--quiet", "-b", "main"], in: work)
        var ids: [String] = []
        for files in commits {
            for (name, text) in files {
                let url = work.appending(path: name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            try await extra(work)
            try await git(["add", "-A"], in: work)
            try await staged(work)
            try await git(["commit", "--quiet", "-m", "c"], in: work)
            ids.append(try await git(["rev-parse", "HEAD"], in: work))
        }
        try await git(["clone", "--quiet", "--bare", work.path, bare.path])
        return ids
    }

    func fetcher(run: GitPackFetcher.Run? = nil) -> GitPackFetcher {
        run.map { GitPackFetcher(git: Self.git, root: root, allowLocal: true, run: $0) } ?? GitPackFetcher(git: Self.git, root: root, allowLocal: true)
    }
}

@Suite("Git pack fetcher")
struct GitPackFetcherTests {
    @Test func installsOnePinnedCommitAtNameAtCommitAndDropsTheGitFolder() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let ids = try await f.makeRepo(commits: [["rigging.yaml": Fixture.pack], ["README.md": "second"]])
        let first = try await f.fetcher().fetch(url: f.bare.path, ref: ids[0])
        #expect(first.commit == ids[0])
        #expect(first.directory.lastPathComponent == "sample-pack@\(ids[0])")
        #expect(first.loaded.pack.metadata.name == "sample-pack")
        #expect(!FileManager.default.fileExists(atPath: first.directory.appending(path: ".git").path))
        #expect(!FileManager.default.fileExists(atPath: first.directory.appending(path: "README.md").path), "the pinned commit is checked out, not the branch tip")
        let tip = try await f.fetcher().fetch(url: f.bare.path, ref: nil)
        #expect(tip.commit == ids[1])
        #expect(FileManager.default.fileExists(atPath: tip.directory.appending(path: "README.md").path))
        let branch = try await f.fetcher().fetch(url: f.bare.path, ref: "main")
        #expect(branch.commit == ids[1])
        // Nothing is left in staging.
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).filter { $0.hasPrefix(".staging-") }.isEmpty)
        f.fetcher().prune(name: "sample-pack", keep: tip.directory.lastPathComponent)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path) == [tip.directory.lastPathComponent])
    }

    @Test func everyGitRunHasNoHooksAndACleanEnvironment() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        _ = try await f.makeRepo(commits: [["rigging.yaml": Fixture.pack]])
        let seen = Mutex<[ProcessSpec]>([])
        _ = try await f.fetcher(run: { spec in
            seen.withLock { $0.append(spec) }
            return try await Subprocess.run(spec)
        }).fetch(url: f.bare.path, ref: nil)
        let specs = seen.withLock { $0 }
        #expect(specs.count >= 4)
        for spec in specs {
            #expect(spec.executable.path == "/usr/bin/git")
            #expect(spec.arguments.contains("core.hooksPath=/dev/null"), "\(spec.arguments)")
            #expect(spec.arguments.contains("protocol.ext.allow=never"))
            #expect(!spec.environment.keys.contains("SSH_AUTH_SOCK") && !spec.environment.keys.contains("GIT_SSH_COMMAND"))
            #expect(spec.environment["GIT_CONFIG_GLOBAL"] == "/dev/null" && spec.environment["GIT_CONFIG_NOSYSTEM"] == "1" && spec.environment["GIT_TERMINAL_PROMPT"] == "0")
            #expect(spec.environment["HOME"]?.contains(".staging-") == true)
            #expect(Set(spec.environment.keys).isSubset(of: ["PATH", "HOME", "LC_ALL", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL", "GIT_TERMINAL_PROMPT", "GIT_ASKPASS", "GIT_ALLOW_PROTOCOL", "GIT_OPTIONAL_LOCKS", "GIT_CEILING_DIRECTORIES"]))
        }
        let clone = try #require(specs.first { $0.arguments.contains("clone") })
        #expect(clone.arguments.contains("--no-checkout") && clone.arguments.contains("--no-recurse-submodules"))
        let checkout = try #require(specs.first { $0.arguments.contains("checkout") })
        #expect(checkout.arguments.contains("--detach"))
    }

    @Test func theCloneIsShallowAndNeverFollowsRedirects() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        _ = try await f.makeRepo(commits: [["rigging.yaml": Fixture.pack]])
        let seen = Mutex<[ProcessSpec]>([])
        _ = try await f.fetcher(run: { spec in
            seen.withLock { $0.append(spec) }
            return try await Subprocess.run(spec)
        }).fetch(url: f.bare.path, ref: nil)
        let specs = seen.withLock { $0 }
        for spec in specs { #expect(spec.arguments.contains("http.followRedirects=false"), "\(spec.arguments)") }
        let clone = try #require(specs.first { $0.arguments.contains("clone") })
        #expect(clone.arguments.contains("--depth=1") && clone.arguments.contains("--single-branch"))
    }

    @Test func aRepositoryThatGrowsPastTheCapIsStopped() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        _ = try await f.makeRepo(commits: [["rigging.yaml": Fixture.pack]])
        var fetcher = f.fetcher(run: { spec in
            let staging = try #require(spec.environment["HOME"]).split(separator: "/").dropLast().joined(separator: "/")
            try Data(count: GitPackFetcher.maxStagingBytes + 1024).write(to: URL(fileURLWithPath: "/" + staging + "/big"))
            try await Task.sleep(for: .seconds(20))
            return try await Subprocess.run(spec)
        })
        fetcher.stagingPoll = .milliseconds(20)
        await #expect(throws: GitPackFetcher.FetchError.self) { try await fetcher.fetch(url: f.bare.path, ref: nil) }
    }

    @Test func tooManyFilesTooManyBytesAndGitmodulesAreRefused() async throws {
        let many = try Fixture()
        defer { many.cleanup() }
        var files: [String: String] = ["rigging.yaml": Fixture.pack]
        for i in 0...GitPackFetcher.maxEntries { files["f\(i).txt"] = "x" }
        _ = try await many.makeRepo(commits: [files])
        await #expect(throws: GitPackFetcher.FetchError.self) { try await many.fetcher().fetch(url: many.bare.path, ref: nil) }

        let big = try Fixture()
        defer { big.cleanup() }
        _ = try await big.makeRepo(commits: [["rigging.yaml": Fixture.pack, "big.txt": String(repeating: "x", count: GitPackFetcher.maxBytes + 10)]])
        await #expect(throws: GitPackFetcher.FetchError.self) { try await big.fetcher().fetch(url: big.bare.path, ref: nil) }

        let modules = try Fixture()
        defer { modules.cleanup() }
        _ = try await modules.makeRepo(commits: [["rigging.yaml": Fixture.pack, ".gitmodules": "[submodule \"x\"]\n"]])
        await #expect(throws: GitPackFetcher.FetchError.self) { try await modules.fetcher().fetch(url: modules.bare.path, ref: nil) }
    }

    @Test func aSymbolicLinkInTheTreeRefusesThePackBeforeAnythingIsWritten() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        _ = try await f.makeRepo(commits: [["rigging.yaml": Fixture.pack]]) { work in
            try? FileManager.default.removeItem(at: work.appending(path: "link"))
            try FileManager.default.createSymbolicLink(at: work.appending(path: "link"), withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        }
        await #expect(throws: GitPackFetcher.FetchError.self) { try await f.fetcher().fetch(url: f.bare.path, ref: nil) }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: f.root.path)) ?? []
        #expect(left.isEmpty, "\(left)")
    }

    @Test func aSubmoduleEntryRefusesThePack() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        _ = try await f.makeRepo(commits: [["rigging.yaml": Fixture.pack]], staged: { work in
            try await f.git(["update-index", "--add", "--cacheinfo", "160000,\(String(repeating: "a", count: 40)),sub"], in: work)
        })
        await #expect(throws: GitPackFetcher.FetchError.self) { try await f.fetcher().fetch(url: f.bare.path, ref: nil) }
    }

    @Test func anInvalidOrMissingPackFileIsRefusedAndLeavesNothingBehind() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        _ = try await f.makeRepo(commits: [["rigging.yaml": Fixture.pack.replacingOccurrences(of: "kind: Pack", with: "kind: Pack\nscript: run")]])
        await #expect(throws: GitPackFetcher.FetchError.self) { try await f.fetcher().fetch(url: f.bare.path, ref: nil) }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: f.root.path)) ?? []).isEmpty)
    }

    @Test func anUnknownRefIsReported() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        _ = try await f.makeRepo(commits: [["rigging.yaml": Fixture.pack]])
        await #expect(throws: GitPackFetcher.FetchError.self) { try await f.fetcher().fetch(url: f.bare.path, ref: "no-such-branch") }
    }

    @Test func aHookInTheRepositoryNeverRuns() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let marker = f.base.appending(path: "hook-ran")
        // A hook file committed to the tree is just a file; and one planted in the clone's own hooks folder is ignored through hooksPath.
        _ = try await f.makeRepo(commits: [["rigging.yaml": Fixture.pack, ".githooks/post-checkout": "#!/bin/sh\ntouch '\(marker.path)'\n"]])
        let seen = Mutex<Bool>(false)
        _ = try await f.fetcher(run: { spec in
            // Plant a post-checkout hook in the fresh clone right before the checkout, as a template directory would have.
            if spec.arguments.contains("checkout"), let dir = spec.currentDirectory {
                let hooks = dir.appending(path: ".git/hooks")
                try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
                let hook = hooks.appending(path: "post-checkout")
                try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: hook, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
                seen.withLock { $0 = true }
            }
            return try await Subprocess.run(spec)
        }).fetch(url: f.bare.path, ref: nil)
        #expect(seen.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func urlsAndRefsAreValidated() throws {
        let fetcher = GitPackFetcher(git: Fixture.git, root: URL(fileURLWithPath: "/tmp/x"))
        for good in ["https://github.com/example/rigging-pack.git", "https://example.org/a/b"] { #expect(try fetcher.validate(url: good) == good) }
        for bad in ["http://example.org/a", "git@github.com:a/b.git", "ssh://git@example.org/a", "ext::sh -c id", "-oProxyCommand=id", "--upload-pack=id", "file:///tmp/x", "/tmp/x",
                    "https://user:secret@example.org/a", "https://example.org/a?x=1", "https://example.org/a\nb", "", "https://", "https://example.org/a b", "https://ex\u{0430}mple.org/a", "https://例え.jp/a"] {
            #expect(throws: GitPackFetcher.FetchError.self, "\(bad)") { try fetcher.validate(url: bad) }
        }
        #expect(try GitPackFetcher.validate(ref: " v1.2.3 ") == "v1.2.3")
        #expect(try GitPackFetcher.validate(ref: nil) == nil)
        #expect(throws: GitPackFetcher.FetchError.self) { try GitPackFetcher.validate(ref: "abc1234") }
        for bad in ["--exec=id", "-x", "a..b", "a b", "a;b", "a$(id)", "x.lock", "a/", String(repeating: "a", count: 300)] {
            #expect(throws: GitPackFetcher.FetchError.self, "\(bad)") { try GitPackFetcher.validate(ref: bad) }
        }
    }
}

@Suite("Pack folder reader")
struct PackFolderTests {
    private func makeFolder() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appending(path: "wh-pack-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Fixture.pack.write(to: dir.appending(path: "rigging.yaml"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func readsAPlainFolderAndReportsTheDigest() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let loaded = try RiggingPackFolder.load(dir)
        #expect(loaded.pack.metadata.name == "sample-pack")
        #expect(loaded.digest == RiggingPackFolder.digest(of: Data(Fixture.pack.utf8)))
    }

    @Test func symlinksAreRefusedEverywhere() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appending(path: "icons"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "icons/a.pdf"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(throws: RiggingPackError.self) { try RiggingPackFolder.load(dir) }
        try FileManager.default.removeItem(at: dir.appending(path: "icons/a.pdf"))
        #expect((try? RiggingPackFolder.load(dir)) != nil)
        // rigging.yaml itself a link to a real file elsewhere.
        let outside = dir.deletingLastPathComponent().appending(path: "outside-\(UUID().uuidString).yaml")
        try Fixture.pack.write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.removeItem(at: dir.appending(path: "rigging.yaml"))
        try FileManager.default.createSymbolicLink(at: dir.appending(path: "rigging.yaml"), withDestinationURL: outside)
        #expect(throws: RiggingPackError.self) { try RiggingPackFolder.load(dir) }
    }

    @Test func aLinkedFolderRootAndAMissingFileAreRefused() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.deletingLastPathComponent().appending(path: "link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        defer { try? FileManager.default.removeItem(at: link) }
        #expect(throws: RiggingPackError.self) { try RiggingPackFolder.load(link) }
        try FileManager.default.removeItem(at: dir.appending(path: "rigging.yaml"))
        #expect(throws: RiggingPackError.self) { try RiggingPackFolder.load(dir) }
    }

    @Test func aHugeFileIsRefused() throws {
        let dir = try makeFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 0x61, count: 300 * 1024).write(to: dir.appending(path: "rigging.yaml"))
        #expect(throws: RiggingPackError.self) { try RiggingPackFolder.load(dir) }
    }
}
#endif
