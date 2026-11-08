import SwiftUI
import WheelhouseKit

/// How far back to read.
enum LogSince: Hashable, CaseIterable, Identifiable {
    case all, minutes5, hour1, hours6, hours24
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All"
        case .minutes5: "5 min"
        case .hour1: "1 hour"
        case .hours6: "6 hours"
        case .hours24: "24 hours"
        }
    }
    var seconds: Int? {
        switch self {
        case .all: nil
        case .minutes5: 300
        case .hour1: 3600
        case .hours6: 6 * 3600
        case .hours24: 24 * 3600
        }
    }
}

enum LogTail: Int, CaseIterable, Identifiable {
    case l100 = 100, l500 = 500, l1000 = 1000, l5000 = 5000, all = 0
    var id: Int { rawValue }
    var title: String { self == .all ? "All lines" : "Last \(rawValue)" }
    var lines: Int? { self == .all ? nil : rawValue }
}

/// Compiled search query (plain text or regex, case-insensitive).
struct LogMatcher {
    private let needle: String
    private let regex: NSRegularExpression?

    init?(query: String, regex useRegex: Bool) {
        guard !query.isEmpty else { return nil }
        needle = query
        if useRegex {
            guard let r = try? NSRegularExpression(pattern: query, options: [.caseInsensitive]) else { return nil }
            regex = r
        } else { regex = nil }
    }

    func ranges(in text: String) -> [NSRange] {
        let ns = text as NSString
        if let regex {
            return regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)).map(\.range).filter { $0.length > 0 }
        }
        var out: [NSRange] = []
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let r = ns.range(of: needle, options: [.caseInsensitive, .literal], range: search)
            if r.location == NSNotFound { break }
            out.append(r)
            let next = r.location + max(r.length, 1)
            search = NSRange(location: next, length: ns.length - next)
        }
        return out
    }

    func matches(_ text: String) -> Bool {
        if regex != nil { return !ranges(in: text).isEmpty }
        return text.range(of: needle, options: [.caseInsensitive, .literal]) != nil
    }
}

/// State of one log screen: the stream, display options, search and follow behaviour.
@MainActor @Observable
final class LogsModel: Identifiable {
    let id = UUID()
    let pod: ResourceRef
    let requestedContainer: String?
    let clusterSession: ClusterSession
    let stream: LogStream
    let startedAt = Date()

    // Source
    private(set) var container: String?
    private(set) var containers: [String] = []
    private(set) var allContainers = false
    private(set) var previous: Bool
    var since: LogSince = .all
    var tail: LogTail = .l1000
    private(set) var podLoaded = false
    private(set) var podError: KubeError?
    private(set) var suggestPrevious = false
    private(set) var terminationNote: String?
    /// `spec.nodeName` of the pod; named in the inotify banner.
    private(set) var nodeName: String?
    /// A pinned stream keeps running when the screen is left (it still stops when the app goes to the background).
    var pinned = false

    // Display
    var timestamps = false
    var wrap = true
    var fontSize: CGFloat
    var follow = true

    // Visible lines + search
    /// The lines the list shows. Only the list reads it: a screen part that only needs "any lines?" or the count reads ``hasLines``
    /// or the status values below, so a flush of new lines re-renders the list and nothing else.
    private(set) var visible: [LogLine] = []
    /// `visible` without registering an observation: the Mac table reads it while SwiftUI may be tracking (`updateNSView`), and a
    /// tracked read there would put every flush back on SwiftUI's path. It observes `visible.count` itself instead.
    var untrackedVisible: [LogLine] { _visible }
    /// `!visible.isEmpty`, written only when it changes.
    private(set) var hasLines = false
    /// The footer's line and dropped counts. Where the stream enforces the desktop limits they change at most once a second
    /// (ARCHITECTURE-MAC section 12.3.2: status bars update at most once a second), always with a trailing update so the last value
    /// lands; elsewhere (iOS) they follow every flush, as before.
    private(set) var statusLineCount = 0
    private(set) var statusDroppedCount = 0
    var query = "" { didSet { if oldValue != query { queryChanged() } } }
    var useRegex = false { didSet { if oldValue != useRegex { queryChanged() } } }
    var matchesOnly = false { didSet { if oldValue != matchesOnly { syncFromStream(force: true) } } }
    private(set) var matcher: LogMatcher?
    private(set) var matchIDs: [Int] = []
    private(set) var currentMatch: Int?
    private(set) var scrollTarget: ScrollTarget?
    private(set) var newLinesWhileAway = 0
    var isSearching = false

    struct ScrollTarget: Equatable { var lineID: Int; var token: Int }

    @ObservationIgnored private var scannedUpTo = -1
    @ObservationIgnored private var lastCount = 0
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var markerAdded = false
    @ObservationIgnored private var syncedEpoch = -1
    @ObservationIgnored private var isOnScreen = false
    /// `load()` finished (or was cancelled) while the screen was gone or the app in the background: start on return.
    @ObservationIgnored private var startDeferred = false
    @ObservationIgnored private var syncedAppended = 0
    @ObservationIgnored private var syncedDropped = 0
    @ObservationIgnored private var streamSyncGeneration = 0
    @ObservationIgnored private var streamSyncClients = 0
    @ObservationIgnored private var statusUpdatedAt: ContinuousClock.Instant?
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    /// `maxLines` and `fontSize` come from Settings (`AppPreferences.logMaxLines` / `logFontSize`).
    /// `limits` is a test seam; the app uses the platform default (desktop caps on the Mac, unlimited on iOS).
    init(pod: ResourceRef, container: String?, previous: Bool, session: ClusterSession, maxLines: Int = 20_000, fontSize: Double = 12,
         limits: LogLimits = .platformDefault) {
        self.stream = LogStream(capacity: min(max(maxLines, 1_000), limits.maxLines), limits: limits)
        self.fontSize = CGFloat(min(max(fontSize, 9), 22))
        self.pod = pod
        self.requestedContainer = container
        self.container = container
        self.previous = previous
        self.clusterSession = session
        self.follow = !previous
    }

    var currentLineID: Int? { currentMatch.flatMap { matchIDs.indices.contains($0) ? matchIDs[$0] : nil } }
    var isLive: Bool { stream.isLive }
    var title: String { allContainers ? "all containers" : (container ?? "default container") }

    // MARK: Loading

    /// Loads the pod (container names, restart info) and starts streaming.
    func load() async {
        podError = nil
        if let ns = pod.namespace {
            do {
                let p = try await clusterSession.client.get(Pod.self, name: pod.name, namespace: ns)
                nodeName = p.spec.nodeName
                containers = (p.spec.initContainers + p.spec.containers).map(\.name)
                if container == nil { container = p.metadata.annotations["kubectl.kubernetes.io/default-container"] ?? p.spec.containers.first?.name }
                if let name = container {
                    let status = (p.status?.containerStatuses ?? []) + (p.status?.initContainerStatuses ?? [])
                    let s = status.first { $0.name == name }
                    let crashing = s?.state?.waiting?.reason == "CrashLoopBackOff" || ((s?.restartCount ?? 0) > 0 && s?.state?.running == nil)
                    suggestPrevious = crashing && !previous && (s?.lastState?.terminated != nil)
                    terminationNote = Self.termination(from: previous ? s?.lastState?.terminated : s?.state?.terminated)
                }
                podLoaded = true
            } catch let e as KubeError {
                podError = e
                if case .notFound = e { stream.appendMarker("Pod no longer exists") }
            } catch {}
        }
        // The user may have left (or the app backgrounded) while the pod was loading: never open a follow off-screen.
        if Task.isCancelled || !mayStream { startDeferred = true; return }
        startStream()
    }

    private var mayStream: Bool { (isOnScreen || pinned) && !SessionsHub.shared.isBackgrounded }

    private static func termination(from t: ContainerState.Terminated?) -> String? {
        guard let t else { return nil }
        return "Container terminated · \(t.reason ?? "Exited") · exit \(t.exitCode)"
    }

    func startStream() {
        guard let ns = pod.namespace else { return }
        markerAdded = false
        let targets: [String?] = allContainers ? containers.map { Optional($0) } : [container]
        var options = LogOptions(follow: !previous, previous: previous, timestamps: true, tailLines: tail.lines, sinceSeconds: since.seconds)
        options.container = container
        stream.start(client: clusterSession.client, namespace: ns, pod: pod.name, containers: targets, options: options, scope: pod.clusterID)
        visible = []; matchIDs = []; scannedUpTo = -1; lastCount = 0; currentMatch = nil; newLinesWhileAway = 0
        visibleDidChange(forceStatus: true)
    }

    func reload() { startStream() }
    func stop() { stream.stop(to: .idle) }

    func clear() {
        stream.clear()
        visible = []; matchIDs = []; scannedUpTo = -1; currentMatch = nil; lastCount = 0
        visibleDidChange(forceStatus: true)
    }

    // MARK: Lifecycle

    /// Every connection is closed in the background (pinned or not); `appWillEnterForeground` brings it back.
    func appDidEnterBackground() { stream.suspend(reason: .background) }

    func appWillEnterForeground() {
        if stream.state == .paused, stream.pauseReason == .background { stream.resume() }
        startDeferredIfPossible()
    }

    private func startDeferredIfPossible() {
        guard startDeferred, mayStream else { return }
        startDeferred = false
        startStream()
    }

    /// Leaving the screen closes the follow connection (the kubelet holds an inotify watcher per follow) unless pinned.
    func screenDidDisappear() {
        isOnScreen = false
        statusTask?.cancel(); statusTask = nil
        stream.isVisible = false
        if !pinned { stream.suspend(reason: .screenLeft) }
    }

    func screenDidAppear() {
        isOnScreen = true
        updateStatus(force: true)
        stream.isVisible = true
        if stream.state == .paused, stream.pauseReason == .screenLeft { stream.resume() }
        startDeferredIfPossible()
    }

    /// True while new lines come from repeated non-follow requests because the node cannot stream.
    var isPolling: Bool { stream.mode == .polling }

    // MARK: Settings

    func setContainer(_ name: String?) {
        if let name { allContainers = false; container = name } else { allContainers = true }
        Task { await load() }
    }

    func setPrevious(_ on: Bool) {
        guard on != previous else { return }
        previous = on
        follow = !on
        suggestPrevious = false
        Task { await load() }
    }

    // MARK: Stream sync

    /// Keeps `visible` in step with the stream without a SwiftUI view in between (the Mac log screen; iOS uses `.onChange`): observes
    /// `stream.revision` and `stream.state` and syncs after each change while at least one screen showing this model has called this
    /// and not yet ``stopStreamSync()`` (one model can be on two screens, and the new one may appear before the old one goes).
    func startStreamSync() {
        streamSyncClients += 1
        guard streamSyncClients == 1 else { return }
        streamSyncGeneration += 1
        armStreamSync(streamSyncGeneration)
        syncFromStream()
    }

    func stopStreamSync() {
        guard streamSyncClients > 0 else { return }
        streamSyncClients -= 1
        if streamSyncClients == 0 { streamSyncGeneration += 1 }
    }

    private func armStreamSync(_ generation: Int) {
        withObservationTracking {
            _ = stream.revision
            _ = stream.state
        } onChange: { [weak self] in
            // Fires before the change; the sync runs on the next main-actor turn, after it.
            Task { @MainActor [weak self] in
                guard let self, self.streamSyncGeneration == generation else { return }
                self.armStreamSync(generation)
                self.syncFromStream()
            }
        }
    }

    /// Called when `stream.revision` changes.
    func syncFromStream(force: Bool = false) {
        let buffer = stream.buffer
        if matchesOnly, let matcher {
            visible = buffer.lines.filter { $0.kind == .marker || matcher.matches($0.message) }
            syncedEpoch = -1
        } else {
            // Incremental: drop what fell off the front of the ring, append what arrived. Rebuilding the array (50 000
            // lines, several refcounted strings each) ten times a second was the main cost of a chatty log.
            let appended = stream.appendedTotal - syncedAppended
            let dropped = buffer.droppedCount - syncedDropped
            if !force, syncedEpoch == stream.epoch, appended >= 0, dropped >= 0, dropped <= visible.count, appended <= buffer.count {
                if dropped > 0 { visible.removeFirst(dropped) }
                if appended > 0 { visible.append(contentsOf: buffer.lines.suffix(appended)) }
            } else {
                visible = Array(buffer.lines)
            }
            syncedEpoch = stream.epoch; syncedAppended = stream.appendedTotal; syncedDropped = buffer.droppedCount
        }
        if !follow, visible.count > lastCount { newLinesWhileAway += visible.count - lastCount }
        if follow, newLinesWhileAway != 0 { newLinesWhileAway = 0 }
        lastCount = visible.count
        visibleDidChange(forceStatus: false)
        rescanMatches(incremental: !force)
        if stream.state == .finished, !markerAdded, let note = terminationNote {
            markerAdded = true
            stream.appendMarker(note)
        }
    }

    // MARK: Derived display state

    /// Seconds between status updates: 1 s where the stream enforces the desktop limits (the Mac), immediate otherwise (iOS).
    private var statusInterval: Duration { stream.limits.isUnlimited ? .zero : .seconds(1) }

    private func visibleDidChange(forceStatus: Bool) {
        let has = !visible.isEmpty
        if hasLines != has { hasLines = has }
        updateStatus(force: forceStatus)
    }

    /// Publishes the footer counts, at most once per ``statusInterval`` unless `force` (a reset must show at once).
    func updateStatus(force: Bool = false) {
        let count = visible.count, dropped = stream.droppedCount
        guard count != statusLineCount || dropped != statusDroppedCount else { return }
        let now = ContinuousClock.now
        if force || statusInterval == .zero || statusUpdatedAt.map({ now - $0 >= statusInterval }) ?? true {
            statusTask?.cancel(); statusTask = nil
            statusUpdatedAt = now
            if statusLineCount != count { statusLineCount = count }
            if statusDroppedCount != dropped { statusDroppedCount = dropped }
            return
        }
        guard statusTask == nil, let last = statusUpdatedAt else { return }
        let wait = statusInterval - (now - last)
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.statusTask = nil
            self.updateStatus(force: true)
        }
    }

    // MARK: Search

    private func queryChanged() {
        matcher = LogMatcher(query: query, regex: useRegex)
        scannedUpTo = -1
        matchIDs = []
        currentMatch = nil
        if matchesOnly { syncFromStream(force: true) } else { rescanMatches(incremental: false) }
        if !matchIDs.isEmpty { currentMatch = matchIDs.count - 1; jumpToCurrent() }
    }

    private func rescanMatches(incremental: Bool) {
        // Written only when they change: these are observed, and this runs on every flush.
        guard let matcher else {
            if !matchIDs.isEmpty { matchIDs = [] }
            if currentMatch != nil { currentMatch = nil }
            return
        }
        if !incremental { if !matchIDs.isEmpty { matchIDs = [] }; scannedUpTo = -1 }
        // Drop matches that scrolled out of the ring buffer.
        if let first = visible.first?.id, let oldest = matchIDs.first, oldest < first { matchIDs.removeAll { $0 < first } }
        let start = visible.firstIndex { $0.id > scannedUpTo } ?? visible.count
        let found = visible[start...].filter { $0.kind == .line && matcher.matches($0.message) }.map(\.id)
        if !found.isEmpty { matchIDs.append(contentsOf: found) }
        scannedUpTo = visible.last?.id ?? scannedUpTo
        if matchIDs.isEmpty {
            if currentMatch != nil { currentMatch = nil }
        } else if let c = currentMatch, c >= matchIDs.count { currentMatch = matchIDs.count - 1 }
    }

    func nextMatch() {
        guard !matchIDs.isEmpty else { return }
        currentMatch = ((currentMatch ?? -1) + 1) % matchIDs.count
        jumpToCurrent()
    }

    func previousMatch() {
        guard !matchIDs.isEmpty else { return }
        currentMatch = ((currentMatch ?? 0) - 1 + matchIDs.count) % matchIDs.count
        jumpToCurrent()
    }

    private func jumpToCurrent() {
        guard let id = currentLineID else { return }
        follow = false
        token += 1
        scrollTarget = ScrollTarget(lineID: id, token: token)
    }

    func jumpToLive() {
        follow = true
        newLinesWhileAway = 0
        token += 1
        scrollTarget = ScrollTarget(lineID: -1, token: token)
    }

    func userScrolledAway() { if follow { follow = false } }
    func userReachedBottom() { if !follow { follow = true; newLinesWhileAway = 0 } }

    // MARK: Export

    func exportText() -> String {
        visible.map { $0.kind == .marker ? "── \($0.message) ──" : $0.text(timestamps: true) }.joined(separator: "\n") + "\n"
    }

    func exportFileURL() -> URL? {
        let name = "\(pod.name)-\(container ?? "logs")-\(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted)))"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).log")
        do { try exportText().write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
    }
}
