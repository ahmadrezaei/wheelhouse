#if os(macOS)
import CoreServices
import Foundation
import Synchronization

/// What a batch of file-system events means for the watcher's owner.
public struct FileChange: Sendable, Equatable {
    /// Watched files or folder-source files that were touched (canonical, standardised paths).
    public var paths: Set<String>
    /// The watched root moved, or events were dropped: re-scan everything.
    public var needsFullRescan: Bool
}

/// ONE FSEventStream over the deduplicated parent directories of every source file plus the folder sources (ARCHITECTURE-MAC §4.3).
/// Event driven: there is no polling anywhere. Latency 0.5 s on its own dispatch queue.
public final class FileWatcher: Sendable {
    private struct State: @unchecked Sendable {
        var stream: FSEventStreamRef?
        var files: Set<String> = []
        var folders: [String: Bool] = [:]   // folder path -> recursive
    }
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "app.wheelhouse.moorings.fsevents", qos: .utility)
    private let latency: TimeInterval
    private let handler: @Sendable (FileChange) -> Void

    public init(latency: TimeInterval = 0.5, handler: @escaping @Sendable (FileChange) -> Void) {
        self.latency = latency
        self.handler = handler
    }

    deinit { stop() }

    /// Replaces the watched set. Files are watched through their parent directory (atomic replaces change the inode).
    public func update(files: Set<String>, folders: [String: Bool]) {
        stop()
        let files = Set(files.map { Self.normalize($0) })
        let folders = Dictionary(uniqueKeysWithValues: folders.map { (Self.normalize($0.key), $0.value) })
        let roots = Set(files.map { ($0 as NSString).deletingLastPathComponent }).union(folders.keys)
        guard !roots.isEmpty else { return }
        state.withLock { s in s.files = files; s.folders = folders }

        let box = Unmanaged.passRetained(WatcherBox(owner: self))
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: { info in
            if let info { Unmanaged<WatcherBox>.fromOpaque(info).release() }
        }, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        let callback: FSEventStreamCallback = { _, info, count, paths, eventFlags, _ in
            guard let info else { return }
            let owner = Unmanaged<WatcherBox>.fromOpaque(info).takeUnretainedValue().owner
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var flagList: [UInt32] = []
            for i in 0..<count { flagList.append(eventFlags[i]) }
            owner?.deliver(paths: list, flags: flagList)
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, Array(roots) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               latency, flags) else {
            box.release()
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        state.withLock { $0.stream = stream }
    }

    public func stop() {
        let stream = state.withLock { s -> FSEventStreamRef? in defer { s.stream = nil }; return s.stream }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// True while a stream exists (tests, perf harness).
    public var isRunning: Bool { state.withLock { $0.stream != nil } }

    fileprivate func deliver(paths: [String], flags: [UInt32]) {
        let (files, folders) = state.withLock { ($0.files, $0.folders) }
        var relevant = Set<String>()
        var rescan = false
        for (i, raw) in paths.enumerated() {
            let flag = i < flags.count ? flags[i] : 0
            if flag & UInt32(kFSEventStreamEventFlagRootChanged) != 0
                || flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
                || flag & UInt32(kFSEventStreamEventFlagUserDropped) != 0
                || flag & UInt32(kFSEventStreamEventFlagKernelDropped) != 0 {
                rescan = true
            }
            let path = Self.normalize(raw)
            // A rename in a watched folder may be a watched file moving away or back (only one side is always reported).
            if flag & UInt32(kFSEventStreamEventFlagItemRenamed) != 0, !KubeconfigLoader.isIgnoredName((path as NSString).lastPathComponent),
               files.contains(where: { ($0 as NSString).deletingLastPathComponent == (path as NSString).deletingLastPathComponent }) {
                rescan = true
            }
            if Self.isRelevant(path: path, files: files, folders: folders) { relevant.insert(path) }
        }
        guard rescan || !relevant.isEmpty else { return }
        handler(FileChange(paths: relevant, needsFullRescan: rescan))
    }

    // MARK: Filtering

    static func normalize(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }

    /// A path matters when it is a watched file, or a candidate file inside a folder source (one level, or deeper when recursive).
    /// Lock and temporary files never matter.
    public static func isRelevant(path: String, files: Set<String>, folders: [String: Bool]) -> Bool {
        let name = (path as NSString).lastPathComponent
        if KubeconfigLoader.isIgnoredName(name) { return false }
        // Path normalisation resolves symlinks of the parent only, so compare on standardised paths.
        if files.contains(path) { return true }
        let parent = (path as NSString).deletingLastPathComponent
        for (folder, recursive) in folders {
            let inside = recursive ? (parent == folder || parent.hasPrefix(folder + "/")) : parent == folder
            if inside, KubeconfigLoader.isCandidateName(name) { return true }
        }
        return false
    }
}

private final class WatcherBox {
    weak var owner: FileWatcher?
    init(owner: FileWatcher) { self.owner = owner }
}
#endif
