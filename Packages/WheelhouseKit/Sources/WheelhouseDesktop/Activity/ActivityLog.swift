#if os(macOS)
import Foundation
import SQLite3
import Synchronization
import WheelhouseKit

/// A stored entry with its row id.
public struct ActivityRecord: Hashable, Sendable, Identifiable {
    public var id: Int64
    public var entry: ActivityEntry
}

/// What the Activity window asks for.
public struct ActivityQuery: Hashable, Sendable {
    public var text: String
    public var cluster: ClusterID?
    public var since: Date?
    public var limit: Int

    public init(text: String = "", cluster: ClusterID? = nil, since: Date? = nil, limit: Int = 2_000) {
        self.text = text
        self.cluster = cluster
        self.since = since
        self.limit = limit
    }
}

/// The local audit log (ARCHITECTURE-MAC section 12.4): SQLite at `AppPaths.activityDatabase`, retention 90 days.
///
/// Records UI mutations, plugin runs and, in later milestones, Gangway, Beacon and First Mate events: time, cluster, origin, verb,
/// object, result and (terminal origin) the command line as reported by the user's shell. Never request bodies or Secret values.
///
/// The database is opened lazily on the log's own serial queue, on the first record or query, never at launch. `record` returns
/// at once. Rows older than the retention are removed when the database opens and after every 500 inserts (no timer).
public final class ActivityLog: ActivityLogging, @unchecked Sendable {
    public static let retentionDays = 90
    static let pruneEvery = 500
    static let maxFieldLength = 2_000

    private let url: URL
    private let retention: TimeInterval
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "com.ahmadrezaei.wheelhouse.activity", qos: .utility)
    private var db: OpaquePointer?          // touched only on `queue`
    private var inserts = 0                 // touched only on `queue`
    private var openFailed = false          // touched only on `queue`
    private let terminating = Mutex(false)

    public init(url: URL, retentionDays: Int = ActivityLog.retentionDays, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.retention = TimeInterval(retentionDays) * 86_400
        self.now = now
    }

    deinit { sqlite3_close(db) }

    /// True once the database file has been opened (tests assert that creating the log opens nothing).
    public var isOpen: Bool { queue.sync { db != nil } }

    // MARK: Recording

    public func record(_ entry: ActivityEntry) {
        let write = { [self] in
            guard let db = openIfNeeded() else { return }
            insert(entry, into: db)
            inserts += 1
            if inserts % Self.pruneEvery == 0 { prune(db) }
        }
        // Once the app is quitting, a record is written before `record` returns: the shutdown audits of the `willTerminate`
        // observers (Gangway's revoked sessions, for example) run in no fixed order relative to the app delegate's last flush.
        // Audits a cancelled connection task records after the process has begun to exit can still be lost; nothing here can wait
        // for those.
        if terminating.withLock({ $0 }) {
            dispatchPrecondition(condition: .notOnQueue(queue))
            queue.sync(execute: write)
        } else {
            queue.async(execute: write)
        }
    }

    /// Waits for everything recorded so far to be written (tests, export, quit).
    public func flush() { queue.sync {} }

    /// The app is quitting: everything recorded so far is written now, and every later `record` writes synchronously, so no
    /// entry is lost to the process ending. Idempotent.
    public func beginTermination() {
        terminating.withLock { $0 = true }
        flush()
    }

    /// True once `beginTermination()` has been called.
    public var isTerminating: Bool { terminating.withLock { $0 } }

    // MARK: Reading

    /// Newest first.
    public func records(_ query: ActivityQuery = ActivityQuery()) async -> [ActivityRecord] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: select(query)) }
        }
    }

    /// Everything in the log, oldest first (exports).
    public func allRecords() async -> [ActivityRecord] {
        await records(ActivityQuery(limit: Int(Int32.max))).reversed()
    }

    public func count() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let db = openIfNeeded() else { continuation.resume(returning: 0); return }
                continuation.resume(returning: scalar(db, "SELECT COUNT(*) FROM activity"))
            }
        }
    }

    /// How many entries match `query` (its limit is ignored), by SQL COUNT.
    public func count(matching query: ActivityQuery) async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: countMatching(query)) }
        }
    }

    public func clear() {
        queue.async { [self] in
            guard let db = openIfNeeded() else { return }
            sqlite3_exec(db, "DELETE FROM activity", nil, nil, nil)
        }
    }

    // MARK: SQLite (on `queue` only)

    private func openIfNeeded() -> OpaquePointer? {
        if let db { return db }
        guard !openFailed else { return nil }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            openFailed = true
            return nil
        }
        let schema = """
        CREATE TABLE IF NOT EXISTS activity (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            time REAL NOT NULL, cluster TEXT, origin TEXT NOT NULL, origin_label TEXT NOT NULL,
            verb TEXT NOT NULL, object TEXT, result TEXT NOT NULL, command_line TEXT);
        CREATE INDEX IF NOT EXISTS activity_time ON activity(time);
        """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else { sqlite3_close(handle); openFailed = true; return nil }
        db = handle
        prune(handle)
        return handle
    }

    private func prune(_ db: OpaquePointer) {
        let cutoff = now().timeIntervalSince1970 - retention
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM activity WHERE time < ?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff)
        sqlite3_step(stmt)
    }

    private func scalar(_ db: OpaquePointer, _ sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ text: String?) {
        guard let text else { sqlite3_bind_null(stmt, index); return }
        sqlite3_bind_text(stmt, index, String(text.prefix(Self.maxFieldLength)), -1, Self.transient)
    }

    private func insert(_ entry: ActivityEntry, into db: OpaquePointer) {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO activity (time, cluster, origin, origin_label, verb, object, result, command_line) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, entry.time.timeIntervalSince1970)
        bind(stmt, 2, entry.cluster)
        bind(stmt, 3, (try? JSONEncoder().encode(entry.origin)).map { String(decoding: $0, as: UTF8.self) } ?? "{}")
        bind(stmt, 4, Self.label(for: entry.origin))
        bind(stmt, 5, entry.verb)
        bind(stmt, 6, entry.object)
        bind(stmt, 7, entry.result)
        bind(stmt, 8, entry.commandLine)
        sqlite3_step(stmt)
    }

    private func countMatching(_ query: ActivityQuery) -> Int {
        guard let db = openIfNeeded() else { return 0 }
        let (sql, binder) = Self.whereClause(query)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM activity" + sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        _ = binder(stmt, self)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// The WHERE clause of a query and a function that binds its values (returns the next free index).
    private static func whereClause(_ query: ActivityQuery) -> (String, (OpaquePointer?, ActivityLog) -> Int32) {
        var clauses: [String] = []
        var texts: [String] = []
        var times: [Double] = []
        if let cluster = query.cluster { clauses.append("cluster = ?"); texts.append(cluster) }
        if let since = query.since { clauses.append("time >= ?"); times.append(since.timeIntervalSince1970) }
        let search = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            let columns = ["verb", "object", "result", "cluster", "origin_label", "command_line"]
            clauses.append("(" + columns.map { "\($0) LIKE ? ESCAPE '\\'" }.joined(separator: " OR ") + ")")
            let escaped = search.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            texts.append(contentsOf: Array(repeating: "%\(escaped)%", count: columns.count))
        }
        let sql = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let hasCluster = query.cluster != nil
        return (sql, { stmt, log in
            var index: Int32 = 1
            var remaining = texts
            if hasCluster { log.bind(stmt, index, remaining.removeFirst()); index += 1 }
            for t in times { sqlite3_bind_double(stmt, index, t); index += 1 }
            for t in remaining { log.bind(stmt, index, t); index += 1 }
            return index
        })
    }

    private func select(_ query: ActivityQuery) -> [ActivityRecord] {
        guard let db = openIfNeeded() else { return [] }
        var clauses: [String] = []
        var texts: [String] = []              // bound in order
        var times: [Double] = []
        if let cluster = query.cluster { clauses.append("cluster = ?"); texts.append(cluster) }
        if let since = query.since { clauses.append("time >= ?"); times.append(since.timeIntervalSince1970) }
        let search = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            let columns = ["verb", "object", "result", "cluster", "origin_label", "command_line"]
            clauses.append("(" + columns.map { "\($0) LIKE ? ESCAPE '\\'" }.joined(separator: " OR ") + ")")
            let escaped = search.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            texts.append(contentsOf: Array(repeating: "%\(escaped)%", count: columns.count))
        }
        let sql = "SELECT id, time, cluster, origin, verb, object, result, command_line FROM activity"
            + (clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")) + " ORDER BY time DESC, id DESC LIMIT ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var index: Int32 = 1
        // Placeholders appear in the order: cluster, since, search columns.
        if query.cluster != nil { bind(stmt, index, texts.removeFirst()); index += 1 }
        for t in times { sqlite3_bind_double(stmt, index, t); index += 1 }
        for t in texts { bind(stmt, index, t); index += 1 }
        sqlite3_bind_int64(stmt, index, Int64(max(1, query.limit)))
        var rows: [ActivityRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ column: Int32) -> String? { sqlite3_column_text(stmt, column).map { String(cString: $0) } }
            let origin = text(3).flatMap { try? JSONDecoder().decode(ChangeOrigin.self, from: Data($0.utf8)) } ?? .ui
            let entry = ActivityEntry(time: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)), cluster: text(2), origin: origin, verb: text(4) ?? "",
                                      object: text(5), result: text(6) ?? "", commandLine: text(7))
            rows.append(ActivityRecord(id: sqlite3_column_int64(stmt, 0), entry: entry))
        }
        return rows
    }

    // MARK: Labels and exports

    /// The origin as the Activity window and the exports show it.
    public static func label(for origin: ChangeOrigin) -> String {
        switch origin {
        case .ui: "UI"
        case .chartRoom: "Chart Room"
        case .tides: "Tides"
        case .survey: "Survey"
        case .firstMate(let c): "First Mate \(c)"
        case .beacon(let c): "Beacon \(c)"
        case .terminal(let s, _): "Deck Terminal \(s)"
        case .rigging(let p): "Rigging \(p)"
        }
    }

    static let csvHeader = ["time", "cluster", "origin", "verb", "object", "result", "command line (reported by your shell)"]

    /// CSV for spreadsheets: fields with commas, quotes or line breaks are quoted, and a cell that a spreadsheet would read as a
    /// formula (`=`, `+`, `-`, `@`, tab, carriage return at the start) gets a leading apostrophe.
    public static func csv(_ records: [ActivityRecord]) -> String {
        func cell(_ value: String?) -> String {
            var v = value ?? ""
            if let first = v.first, "=+-@\t\r".contains(first) { v = "'" + v }
            if v.contains(where: { ",\"\n\r".contains($0) }) { v = "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            return v
        }
        let iso = ISO8601DateFormatter()
        var lines = [csvHeader.joined(separator: ",")]
        for r in records {
            let e = r.entry
            lines.append([iso.string(from: e.time), e.cluster, label(for: e.origin), e.verb, e.object, e.result, e.commandLine].map(cell).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// JSON array, oldest first as given.
    public static func json(_ records: [ActivityRecord]) throws -> Data {
        struct Row: Encodable {
            var time: String; var cluster: String?; var origin: String; var verb: String; var object: String?; var result: String; var commandLine: String?
        }
        let iso = ISO8601DateFormatter()
        let rows = records.map { Row(time: iso.string(from: $0.entry.time), cluster: $0.entry.cluster, origin: label(for: $0.entry.origin), verb: $0.entry.verb,
                                     object: $0.entry.object, result: $0.entry.result, commandLine: $0.entry.commandLine) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(rows)
    }
}
#endif
