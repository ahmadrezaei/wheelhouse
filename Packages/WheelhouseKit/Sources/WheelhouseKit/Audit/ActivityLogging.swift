import Foundation

/// One audited event. Never holds request bodies or Secret values.
public struct ActivityEntry: Codable, Hashable, Sendable {
    public var time: Date
    public var cluster: ClusterID?
    public var origin: ChangeOrigin
    /// "patch", "delete", "scale", "exec", "install"…
    public var verb: String
    /// "deployment/payments-api"
    public var object: String?
    /// "ok", "refused", "failed: <summary>"
    public var result: String
    /// Command line as reported by the user's shell ("reported by your shell"), terminal origin only.
    public var commandLine: String?

    public init(time: Date = Date(), cluster: ClusterID? = nil, origin: ChangeOrigin = .ui, verb: String, object: String? = nil,
                result: String, commandLine: String? = nil) {
        self.time = time
        self.cluster = cluster
        self.origin = origin
        self.verb = verb
        self.object = object
        self.result = result
        self.commandLine = commandLine
    }
}

/// The audit seam. Every milestone can record from day one; the SQLite implementation lives in `WheelhouseDesktop` (M4a).
public protocol ActivityLogging: Sendable {
    func record(_ entry: ActivityEntry)
}

/// The default: records nothing.
public struct NoopActivityLog: ActivityLogging {
    public init() {}
    public func record(_ entry: ActivityEntry) {}
}

/// In-memory log for tests and previews.
public final class InMemoryActivityLog: ActivityLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ActivityEntry] = []
    public init() {}
    public func record(_ entry: ActivityEntry) { lock.withLock { stored.append(entry) } }
    public var entries: [ActivityEntry] { lock.withLock { stored } }
}
