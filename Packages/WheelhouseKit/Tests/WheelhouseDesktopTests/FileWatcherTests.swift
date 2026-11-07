#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WheelhouseDesktop

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [FileChange] = []
    func add(_ c: FileChange) { lock.withLock { all.append(c) } }
    var paths: Set<String> { lock.withLock { Set(all.flatMap(\.paths)) } }
    var rescans: Int { lock.withLock { all.filter(\.needsFullRescan).count } }
    func clear() { lock.withLock { all.removeAll() } }
}

@Suite("FileWatcher filtering")
struct FileWatcherFilterTests {
    @Test func watchedFilesAndFolderCandidatesMatchTemporaryFilesDoNot() {
        let files: Set<String> = ["/k/config"]
        let folders: [String: Bool] = ["/k/configs": false, "/deep": true]
        func r(_ p: String) -> Bool { FileWatcher.isRelevant(path: p, files: files, folders: folders) }
        #expect(r("/k/config"))
        #expect(!r("/k/other"))
        #expect(r("/k/configs/a.yaml"))
        #expect(r("/k/configs/b.yml"))
        #expect(r("/k/configs/my-kubeconfig"))
        #expect(!r("/k/configs/readme.txt"))
        #expect(!r("/k/configs/sub/a.yaml"))                 // one level only
        #expect(r("/deep/x/y/z.yaml"))                       // recursive folder
        #expect(!r("/k/config.lock"))
        #expect(!r("/k/configs/.#a.yaml"))
        #expect(!r("/k/configs/a.yaml~"))
        #expect(!r("/k/configs/a.yaml.swp"))
        #expect(!r("/k/configs/a.yaml.tmp"))
    }
}

@Suite("FileWatcher (FSEvents)", .serialized)
struct FileWatcherTests {
    @Test func anAtomicReplaceIsSeen() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let file = try s.write("config", "one")
        let seen = Seen()
        let w = FileWatcher(latency: 0.1) { seen.add($0) }
        w.update(files: [file.path], folders: [:])
        defer { w.stop() }
        try await Task.sleep(for: .milliseconds(300))
        let tmp = s.root.appending(path: ".config.tmp")
        try "two".write(to: tmp, atomically: false, encoding: .utf8)
        _ = rename(tmp.path, file.path)
        #expect(await eventually { seen.paths.contains(file.path) })
        // The editor's temporary file is never reported.
        #expect(!seen.paths.contains(tmp.path))
    }

    @Test func aRenameAwayAndBackIsSeen() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let file = try s.write("config", "one")
        let seen = Seen()
        let w = FileWatcher(latency: 0.1) { seen.add($0) }
        w.update(files: [file.path], folders: [:])
        defer { w.stop() }
        try await Task.sleep(for: .milliseconds(300))
        let moved = s.root.appending(path: "config.bak")
        _ = rename(file.path, moved.path)
        #expect(await eventually { seen.paths.contains(file.path) })
        try await Task.sleep(for: .milliseconds(500))
        seen.clear()
        _ = rename(moved.path, file.path)
        #expect(await eventually { seen.paths.contains(file.path) || seen.rescans > 0 })
    }

    @Test func aFileThatDoesNotExistYetIsSeenWhenItAppears() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let target = s.root.appending(path: "later.yaml")
        let seen = Seen()
        let w = FileWatcher(latency: 0.1) { seen.add($0) }
        w.update(files: [target.path], folders: [:])
        defer { w.stop() }
        try await Task.sleep(for: .milliseconds(300))
        try "x".write(to: target, atomically: true, encoding: .utf8)
        #expect(await eventually { seen.paths.contains(target.path) })
    }

    @Test func folderSourcesReportCandidatesAndIgnoreEditorFiles() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let folder = try s.dir("folder")
        let seen = Seen()
        let w = FileWatcher(latency: 0.1) { seen.add($0) }
        w.update(files: [], folders: [folder.path: false])
        defer { w.stop() }
        try await Task.sleep(for: .milliseconds(300))
        try "x".write(to: folder.appending(path: "new.yaml"), atomically: true, encoding: .utf8)
        try "x".write(to: folder.appending(path: ".#new.yaml"), atomically: true, encoding: .utf8)
        try "x".write(to: folder.appending(path: "new.yaml.lock"), atomically: true, encoding: .utf8)
        try "x".write(to: folder.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        #expect(await eventually { seen.paths.contains(folder.appending(path: "new.yaml").path) })
        try await Task.sleep(for: .milliseconds(400))
        #expect(seen.paths == [folder.appending(path: "new.yaml").path])
    }

    @Test func stopEndsDelivery() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let file = try s.write("config", "one")
        let seen = Seen()
        let w = FileWatcher(latency: 0.1) { seen.add($0) }
        w.update(files: [file.path], folders: [:])
        #expect(w.isRunning)
        w.stop()
        #expect(!w.isRunning)
        try "two".write(to: file, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(500))
        #expect(seen.paths.isEmpty)
    }
}
#endif
