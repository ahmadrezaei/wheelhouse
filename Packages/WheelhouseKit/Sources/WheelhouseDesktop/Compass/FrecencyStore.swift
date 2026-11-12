#if os(macOS)
import Foundation
import Synchronization

/// How often and how recently each Compass result was chosen (`compass-frecency.json`, local to this Mac). The value of an item is
/// its use count decayed with a 14 day half-life, so last week's habit outranks last year's. At most 500 items are kept. The file
/// holds result keys (`obj|cluster|kind|namespace|name`, `cmd|id`, …) and counts, never data.
public final class FrecencyStore: Sendable {
    public struct Record: Codable, Equatable, Sendable {
        public var count: Int
        public var last: Date
    }

    public static let capacity = 500
    public static let halfLifeDays = 14.0
    public static let maximumBoost = 200

    private struct State: Sendable { var records: [String: Record] = [:]; var dirty = false }
    private let state = Mutex(State())
    private let file: URL?
    private let now: @Sendable () -> Date

    /// `file` nil keeps everything in memory (tests, performance scenarios).
    public init(file: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.now = now
        if let file, let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder.frecency.decode([String: Record].self, from: data) {
            state.withLock { $0.records = decoded }
        }
    }

    public var records: [String: Record] { state.withLock { $0.records } }

    /// A result was chosen.
    public func record(_ key: String) {
        let date = now()
        state.withLock { s in
            var r = s.records[key] ?? Record(count: 0, last: date)
            r.count += 1
            r.last = date
            s.records[key] = r
            if s.records.count > Self.capacity {
                let keep = s.records.sorted { Self.value($0.value, at: date) > Self.value($1.value, at: date) }.prefix(Self.capacity)
                s.records = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
            s.dirty = true
        }
    }

    /// Ranking bonus 0 ... `maximumBoost`.
    public func boost(_ key: String) -> Int {
        let date = now()
        return state.withLock { s in s.records[key].map { Int(min(Double(Self.maximumBoost), Self.value($0, at: date) * 40)) } ?? 0 }
    }

    /// Keys by value, best first (the empty field's "recent" list).
    public func topKeys(prefix: String, limit: Int) -> [String] {
        let date = now()
        return state.withLock { s in
            s.records.filter { $0.key.hasPrefix(prefix) }.sorted { Self.value($0.value, at: date) > Self.value($1.value, at: date) }.prefix(limit).map(\.key)
        }
    }

    static func value(_ r: Record, at date: Date) -> Double {
        Double(r.count) * pow(0.5, max(0, date.timeIntervalSince(r.last)) / 86_400 / halfLifeDays)
    }

    /// Writes the file when something changed (the caller debounces; quit flushes).
    public func flush() {
        guard let file else { return }
        let snapshot: [String: Record]? = state.withLock { s in
            guard s.dirty else { return nil }
            s.dirty = false
            return s.records
        }
        guard let snapshot, let data = try? JSONEncoder.frecency.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    public func clear() {
        state.withLock { $0.records = [:]; $0.dirty = true }
        flush()
    }
}

private extension JSONEncoder {
    static var frecency: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
}

private extension JSONDecoder {
    static var frecency: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
#endif
