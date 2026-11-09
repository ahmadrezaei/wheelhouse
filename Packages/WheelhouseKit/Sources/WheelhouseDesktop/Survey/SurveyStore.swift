#if os(macOS)
import Darwin
import Foundation
import SQLite3
import WheelhouseKit

public enum SurveyStoreError: Error, Equatable, Sendable, LocalizedError {
    case open(String)
    case sql(String)
    public var errorDescription: String? {
        switch self {
        case .open(let m): "Survey's database could not be opened: \(m)"
        case .sql(let m): "Survey's database failed: \(m)"
        }
    }
}

/// One image waiting to be scanned.
public struct ScanQueueItem: Codable, Hashable, Sendable, Identifiable {
    public var id: Int64
    /// The scan target (digest form when known).
    public var image: String
    public var isMutable: Bool
    /// Clusters that run it, in the order their credentials are tried.
    public var clusters: [String]
    public var trigger: ScanTrigger
}

/// `survey.sqlite` under `AppPaths.root` (ARCHITECTURE-MAC §6.1): scan results keyed by (image digest, DB version), the persisted
/// scan queue, the accepted risks and the per-cluster pull-secret opt-in. Opened lazily by Survey or its Settings pane, never at
/// launch. The file is 0600; the schema is versioned with `PRAGMA user_version` and only ever grows (additive migrations), so an older
/// build keeps working on a newer file.
public actor SurveyStore {
    public static let schemaVersion: Int32 = 1
    private let handle: SurveySQLiteHandle

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        handle = try SurveySQLiteHandle(path: url.path)
        try Self.migrate(handle)
    }

    private static func migrate(_ db: SurveySQLiteHandle) throws {
        let current = try db.userVersion()
        if current < 1 {
            try db.transaction {
                try db.exec("""
                CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS scans (id TEXT PRIMARY KEY, image TEXT NOT NULL, digest TEXT, mutable INTEGER NOT NULL, db_version TEXT NOT NULL,
                                                  scanned_at REAL NOT NULL, vulns BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS queue (id INTEGER PRIMARY KEY AUTOINCREMENT, image TEXT NOT NULL, mutable INTEGER NOT NULL, clusters TEXT NOT NULL,
                                                  trigger TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS accepted_risks (id TEXT PRIMARY KEY, body BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS pull_secret_optin (cluster_id TEXT PRIMARY KEY);
                """)
                try db.exec("PRAGMA user_version = 1")
            }
        }
    }

    // MARK: Scans

    public func scan(id: String) throws -> ImageScanResult? {
        try handle.query("SELECT image, digest, mutable, db_version, scanned_at, vulns FROM scans WHERE id = ?", [.text(id)]) { row in
            ImageScanResult(image: row.text(0) ?? "", digest: row.text(1), isMutable: row.int(2) != 0, dbVersion: row.text(3) ?? "",
                            scannedAt: Date(timeIntervalSince1970: row.double(4)),
                            vulnerabilities: (try? JSONDecoder().decode([ImageVulnerability].self, from: row.blob(5))) ?? [])
        }.first
    }

    public func allScans() throws -> [ImageScanResult] {
        try handle.query("SELECT image, digest, mutable, db_version, scanned_at, vulns FROM scans ORDER BY scanned_at DESC", []) { row in
            ImageScanResult(image: row.text(0) ?? "", digest: row.text(1), isMutable: row.int(2) != 0, dbVersion: row.text(3) ?? "",
                            scannedAt: Date(timeIntervalSince1970: row.double(4)),
                            vulnerabilities: (try? JSONDecoder().decode([ImageVulnerability].self, from: row.blob(5))) ?? [])
        }
    }

    public func save(_ scan: ImageScanResult) throws {
        let vulns = try JSONEncoder().encode(scan.vulnerabilities)
        try handle.run("INSERT OR REPLACE INTO scans (id, image, digest, mutable, db_version, scanned_at, vulns) VALUES (?, ?, ?, ?, ?, ?, ?)",
                       [.text(scan.id), .text(scan.image), scan.digest.map { .text($0) } ?? .null, .int(scan.isMutable ? 1 : 0), .text(scan.dbVersion),
                        .double(scan.scannedAt.timeIntervalSince1970), .blob(vulns)])
    }

    /// Drops results older than `age` seconds (kept for the table's size, not for correctness).
    public func prune(olderThan age: TimeInterval, now: Date = Date()) throws {
        try handle.run("DELETE FROM scans WHERE scanned_at < ?", [.double(now.timeIntervalSince1970 - age)])
    }

    // MARK: Queue (persisted so a relaunch can offer Resume; it never starts by itself)

    @discardableResult
    public func enqueue(image: String, isMutable: Bool, clusters: [String], trigger: ScanTrigger) throws -> Int64 {
        if let existing = try handle.query("SELECT id FROM queue WHERE image = ?", [.text(image)], { $0.int(0) }).first { return existing }
        let clusterJSON = String(decoding: try JSONEncoder().encode(clusters), as: UTF8.self)
        try handle.run("INSERT INTO queue (image, mutable, clusters, trigger) VALUES (?, ?, ?, ?)",
                       [.text(image), .int(isMutable ? 1 : 0), .text(clusterJSON), .text(trigger.rawValue)])
        return handle.lastInsertRowID
    }

    public func queue() throws -> [ScanQueueItem] {
        try handle.query("SELECT id, image, mutable, clusters, trigger FROM queue ORDER BY id", []) { row in
            ScanQueueItem(id: row.int(0), image: row.text(1) ?? "", isMutable: row.int(2) != 0,
                          clusters: (row.text(3).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }) ?? [],
                          trigger: ScanTrigger(rawValue: row.text(4) ?? "") ?? .scheduled)
        }
    }

    public func queueCount() throws -> Int { Int(try handle.query("SELECT COUNT(*) FROM queue", []) { $0.int(0) }.first ?? 0) }

    public func removeFromQueue(id: Int64) throws { try handle.run("DELETE FROM queue WHERE id = ?", [.int(id)]) }
    public func clearQueue() throws { try handle.run("DELETE FROM queue", []) }

    // MARK: Accepted risks

    public func acceptedRisks() throws -> AcceptedRiskBook {
        let risks = try handle.query("SELECT body FROM accepted_risks", []) { row in
            try? Self.riskDecoder.decode(AcceptedRisk.self, from: row.blob(0))
        }
        return AcceptedRiskBook(risks: risks.compactMap { $0 })
    }

    /// Replaces the stored risks with `book` in one transaction.
    public func saveAcceptedRisks(_ book: AcceptedRiskBook) throws {
        try handle.transaction {
            try handle.run("DELETE FROM accepted_risks", [])
            for r in book.risks {
                try handle.run("INSERT INTO accepted_risks (id, body) VALUES (?, ?)", [.text(r.id.uuidString), .blob(try Self.riskEncoder.encode(r))])
            }
        }
    }

    /// One-time import of the file M8a wrote. A flag in `meta`, written in the same transaction, makes it run once: risks the user
    /// removes later never come back. The JSON file is left in place.
    @discardableResult
    public func importLegacyRisksOnce(from file: URL) throws -> Bool {
        if try meta("risks_imported") != nil { return false }
        let legacy = AcceptedRiskStorage.load(from: file)
        try handle.transaction {
            for r in legacy.risks {
                try handle.run("INSERT OR IGNORE INTO accepted_risks (id, body) VALUES (?, ?)", [.text(r.id.uuidString), .blob(try Self.riskEncoder.encode(r))])
            }
            try handle.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('risks_imported', '1')", [])
        }
        return true
    }

    private static var riskEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static var riskDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: Pull-secret opt-in (per cluster, off by default)

    public func usesPullSecrets(clusterID: String) throws -> Bool {
        try !handle.query("SELECT 1 FROM pull_secret_optin WHERE cluster_id = ?", [.text(clusterID)]) { $0.int(0) }.isEmpty
    }

    public func setUsesPullSecrets(_ on: Bool, clusterID: String) throws {
        if on { try handle.run("INSERT OR IGNORE INTO pull_secret_optin (cluster_id) VALUES (?)", [.text(clusterID)]) }
        else { try handle.run("DELETE FROM pull_secret_optin WHERE cluster_id = ?", [.text(clusterID)]) }
    }

    // MARK: Meta

    public func meta(_ key: String) throws -> String? { try handle.query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { $0.text(0) }.first ?? nil }
    public func setMeta(_ key: String, _ value: String) throws { try handle.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [.text(key), .text(value)]) }

    public func userVersion() throws -> Int32 { try handle.userVersion() }
}

// MARK: - A thin sqlite3 wrapper (private to Survey: the activity log has its own)

enum SurveySQLiteValue {
    case null, int(Int64), double(Double), text(String), blob(Data)
}

struct SurveySQLiteRow {
    let stmt: OpaquePointer
    func text(_ i: Int32) -> String? { sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_text(stmt, i).map { String(cString: $0) } }
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func blob(_ i: Int32) -> Data {
        guard let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
    }
}

/// Used only from inside ``SurveyStore`` (an actor), so access is serialized.
final class SurveySQLiteHandle: @unchecked Sendable {
    private var db: OpaquePointer?

    init(path: String) throws {
        var raw: OpaquePointer?
        guard sqlite3_open_v2(path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let raw else {
            let message = raw.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(raw)
            throw SurveyStoreError.open(message)
        }
        db = raw
        chmod(path, 0o600)
        sqlite3_busy_timeout(raw, 3_000)
        try exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")
    }

    deinit { sqlite3_close(db) }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }
    private var message: String { String(cString: sqlite3_errmsg(db)) }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SurveyStoreError.sql(message) }
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }

    func userVersion() throws -> Int32 {
        Int32(try query("PRAGMA user_version", []) { $0.int(0) }.first ?? 0)
    }

    private func prepare(_ sql: String, _ values: [SurveySQLiteValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw SurveyStoreError.sql(message) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, v) in values.enumerated() {
            let n = Int32(i + 1)
            switch v {
            case .null: sqlite3_bind_null(stmt, n)
            case .int(let x): sqlite3_bind_int64(stmt, n, x)
            case .double(let x): sqlite3_bind_double(stmt, n, x)
            case .text(let s): sqlite3_bind_text(stmt, n, s, -1, transient)
            case .blob(let d): _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, n, $0.baseAddress, Int32(d.count), transient) }
            }
        }
        return stmt
    }

    func run(_ sql: String, _ values: [SurveySQLiteValue]) throws {
        let stmt = try prepare(sql, values)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw SurveyStoreError.sql(message) }
    }

    func query<T>(_ sql: String, _ values: [SurveySQLiteValue], _ map: (SurveySQLiteRow) throws -> T) throws -> [T] {
        let stmt = try prepare(sql, values)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { out.append(try map(SurveySQLiteRow(stmt: stmt))) }
            else if rc == SQLITE_DONE { return out }
            else { throw SurveyStoreError.sql(message) }
        }
    }
}
#endif
