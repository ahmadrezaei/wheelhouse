import Foundation

/// Problems the *node* (kubelet) reports at the end of a log stream, as opposed to problems of the app or the API server.
///
/// A `follow=true` log request makes the kubelet create an inotify watcher on the container's log file. When the node
/// has used up `fs.inotify.max_user_instances` / `max_user_watches` the kubelet answers with text such as
/// `failed to create fsnotify watcher: too many open files`, which ends the stream. Reconnecting does not help.
public enum LogStreamProblem: Equatable, Sendable {
    case nodeWatchLimit(detail: String)

    public var title: String { "The node ran out of file watchers (inotify)" }

    public var message: String {
        "The node ran out of file watchers (inotify). Kubernetes can't stream live logs from this node until it's fixed."
    }

    /// Commands to raise the limits on the node right now.
    public static let sysctlCommands = """
    sysctl -w fs.inotify.max_user_instances=8192
    sysctl -w fs.inotify.max_user_watches=524288
    """

    /// Persistent configuration, written on the node.
    public static let persistentFix = """
    cat <<'EOF' | sudo tee /etc/sysctl.d/99-inotify.conf
    fs.inotify.max_user_instances = 8192
    fs.inotify.max_user_watches = 524288
    EOF
    sudo sysctl --system
    """

    /// Everything to copy: immediate and persistent fix.
    public static var fullFix: String {
        "# Run on the node (as root)\n" + sysctlCommands + "\n\n# Persist across reboots\n" + persistentFix
    }

    // MARK: Detection

    /// Looks at the last lines a stream delivered (call at the end of a stream; never on lines from the middle).
    public static func detect(lines: [String]) -> LogStreamProblem? {
        for line in lines.suffix(3).reversed() {
            let text = LogParser.splitTimestamp(line).message
            if matchesInotifyExhaustion(text, strict: true) { return .nodeWatchLimit(detail: text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return nil
    }

    /// Looks at the error that ended a stream (HTTP 500 from the API server relaying the kubelet error, or a transport message).
    public static func detect(error: KubeError?) -> LogStreamProblem? {
        guard let error else { return nil }
        var text = error.summary
        var fromServer = false
        if case .server(let status) = error { text += " " + (status.message ?? ""); fromServer = true }
        if case .unreachable(let cause) = error { text = cause }
        // The bare phrase "too many open files" counts only in a server (kubelet) body; elsewhere (client errors,
        // transport messages) it needs an inotify / fsnotify / watcher keyword.
        if matchesInotifyExhaustion(text, strict: !fromServer) { return .nodeWatchLimit(detail: text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    /// `strict` (log lines, which may contain anything the app prints): requires an inotify / fsnotify / watcher keyword.
    /// Non-strict (error messages): the bare phrase "too many open files" also counts.
    static func matchesInotifyExhaustion(_ text: String, strict: Bool) -> Bool {
        let t = text.lowercased()
        if t.contains("failed to create fsnotify watcher") { return true }
        let watcher = t.contains("fsnotify") || t.contains("inotify") || t.contains("watcher")
        let exhausted = t.contains("too many open files") || t.contains("no space left on device")
            || t.contains("user limit on the total number of inotify") || t.contains("limit on the total number of inotify")
        if watcher && exhausted { return true }
        if !strict && t.contains("too many open files") { return true }
        return false
    }
}

/// Exponential backoff for re-opening a follow stream: 1, 2, 4 … capped at 30 s, giving up after `maxAttempts`
/// consecutive short-lived connections. A connection that stayed up for `healthyAfter` seconds resets the sequence.
public struct LogReconnectBackoff: Sendable, Equatable {
    public static let base: TimeInterval = 1
    public static let cap: TimeInterval = 30
    public static let healthyAfter: TimeInterval = 20
    public static let maxAttempts = 8

    public private(set) var attempts = 0
    public init() {}

    /// Delay before the next attempt, or nil when the stream should not be retried any more.
    public mutating func nextDelay(afterRunning seconds: TimeInterval) -> TimeInterval? {
        if seconds >= Self.healthyAfter { attempts = 0 }
        guard attempts < Self.maxAttempts else { return nil }
        let delay = Swift.min(Self.cap, Self.base * pow(2, Double(attempts)))
        attempts += 1
        return delay
    }

    public mutating func reset() { attempts = 0 }
}

/// Removes lines already delivered when polling `…/log?sinceTime=<last timestamp>&timestamps=true` (the API returns
/// lines at or after `sinceTime`, so the newest line is usually repeated). Lines are identified by their timestamp,
/// and by the full line when several share the newest timestamp.
public struct LogPollDeduper: Sendable, Equatable {
    public private(set) var lastStamp: Double?
    /// The newest timestamp exactly as the server sent it; use it as `sinceTime`.
    public private(set) var lastRawStamp: String?
    private var seenAtLast: Set<String> = []

    public init() {}

    /// Returns the lines not seen before, in order, and records them.
    public mutating func accept(_ lines: [String]) -> [String] {
        var out: [String] = []
        for raw in lines where accept(raw) { out.append(raw) }
        return out
    }

    /// Records one line; false when it is a duplicate or older than the newest line seen.
    @discardableResult
    public mutating func accept(_ raw: String) -> Bool {
        guard let stamp = LogParser.splitTimestamp(raw).timestamp, let t = LogTimestamp.parse(stamp) else { return true }
        guard let last = lastStamp else {
            lastStamp = t; lastRawStamp = stamp; seenAtLast = [raw]
            return true
        }
        if t < last { return false }
        if t == last { return seenAtLast.insert(raw).inserted }
        lastStamp = t; lastRawStamp = stamp; seenAtLast = [raw]
        return true
    }
}
