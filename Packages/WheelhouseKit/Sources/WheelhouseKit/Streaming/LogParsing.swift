import Foundation

public enum LogLevel: Int, Comparable, Sendable, CaseIterable {
    case none = 0, debug, info, warn, error

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .none: ""
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warn: "WARN"
        case .error: "ERROR"
        }
    }

    init?(word: Substring) {
        switch word.lowercased() {
        case "trace", "debug", "dbg", "verbose", "d": self = .debug
        case "info", "information", "notice", "i", "log": self = .info
        case "warn", "warning", "w": self = .warn
        case "error", "err", "fatal", "critical", "crit", "panic", "severe", "alert", "emerg", "e", "f": self = .error
        default: return nil
        }
    }
}

public enum LogLineKind: Sendable, Equatable {
    case line
    /// A divider inserted by the app ("Stream reconnected", "Container terminated · OOMKilled · exit 137").
    case marker
}

/// One line of container output.
public struct LogLine: Identifiable, Sendable, Equatable {
    public var id: Int
    /// Text without the leading RFC3339 timestamp.
    public var message: String
    /// The timestamp exactly as sent by the API server.
    public var timestamp: String?
    public var level: LogLevel
    /// Container name, set when several containers are merged.
    public var source: String?
    public var kind: LogLineKind

    public init(id: Int, message: String, timestamp: String? = nil, level: LogLevel = .none, source: String? = nil, kind: LogLineKind = .line) {
        self.id = id; self.message = message; self.timestamp = timestamp; self.level = level; self.source = source; self.kind = kind
    }

    /// Plain-text form for export / copy.
    public func text(timestamps: Bool) -> String {
        var out = ""
        if timestamps, let timestamp { out += timestamp + " " }
        if let source { out += "[\(source)] " }
        return out + message
    }
}

public enum LogParser {
    /// Splits a leading RFC3339 timestamp (as produced by `timestamps=true`) from the message.
    public static func splitTimestamp(_ raw: String) -> (timestamp: String?, message: String) {
        let u = raw.utf8
        // 2024-01-02T03:04:05...  — digits at 0-3, '-' at 4, 'T' at 10
        guard u.count > 20 else { return (nil, raw) }
        var it = u.makeIterator()
        var head: [UInt8] = []
        for _ in 0..<11 { if let b = it.next() { head.append(b) } }
        guard head.count == 11, head[4] == 0x2D, head[7] == 0x2D, head[10] == 0x54,
              head[0...3].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return (nil, raw) }
        guard let space = raw.firstIndex(of: " ") else { return (raw, "") }
        return (String(raw[..<space]), String(raw[raw.index(after: space)...]))
    }

    public static func parse(id: Int, raw: String, source: String? = nil) -> LogLine {
        let (ts, message) = splitTimestamp(raw)
        return LogLine(id: id, message: message, timestamp: ts, level: LogLevelDetector.detect(message), source: source)
    }
}

/// Heuristic level detection: JSON (`"level"`, `"severity"`), logfmt (`level=error`), klog (`E0102 …`),
/// bracketed or bare keywords (`[ERROR]`, `WARN `).
public enum LogLevelDetector {
    public static func detect(_ line: String) -> LogLevel {
        guard let first = line.utf8.first else { return .none }
        if first == UInt8(ascii: "{"), let level = detectJSON(line) { return level }
        if let l = detectLogfmt(line) { return l }
        if let l = detectKlog(line) { return l }
        return detectKeyword(line)
    }

    static func detectJSON(_ line: String) -> LogLevel? {
        guard line.utf8.last == UInt8(ascii: "}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        for key in ["level", "severity", "lvl", "log.level", "levelname", "loglevel"] {
            if let s = obj[key] as? String, let l = LogLevel(word: Substring(s)) { return l }
            if let n = obj[key] as? Int { // bunyan/pino numeric levels
                switch n {
                case ..<30: return .debug
                case 30: return .info
                case 40: return .warn
                default: return .error
                }
            }
        }
        return LogLevel.none
    }

    static func detectLogfmt(_ line: String) -> LogLevel? {
        for key in ["level=", "lvl=", "severity="] {
            guard let r = line.range(of: key) else { continue }
            if r.lowerBound != line.startIndex, !line[line.index(before: r.lowerBound)].isWhitespace, line[line.index(before: r.lowerBound)] != "\"" { continue }
            var rest = line[r.upperBound...]
            if rest.first == "\"" { rest = rest.dropFirst() }
            let word = rest.prefix { $0.isLetter }
            if let l = LogLevel(word: word) { return l }
        }
        return nil
    }

    static func detectKlog(_ line: String) -> LogLevel? {
        // I0102 15:04:05.000000 ...  /  E1231 ...
        let c = Array(line.utf8.prefix(6))
        guard c.count == 6, "IWEF".utf8.contains(c[0]), c[1...4].allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), c[5] == 0x20 else { return nil }
        switch c[0] {
        case UInt8(ascii: "I"): return .info
        case UInt8(ascii: "W"): return .warn
        default: return .error
        }
    }

    static func detectKeyword(_ line: String) -> LogLevel {
        // Level tokens live at the head of the line: `2024-01-02 ERROR app: …`, `[WARN] …`, `INFO  …`.
        let head = line.prefix(80)
        var seen = 0
        for part in head.split(whereSeparator: { " \t[]()<>|:,=".contains($0) }) {
            seen += 1
            if seen > 6 { break }
            if part.count >= 3, part.allSatisfy({ $0.isUppercase }), let l = LogLevel(word: part) { return l }
        }
        let lower = head.lowercased()
        if lower.hasPrefix("error") || lower.hasPrefix("fatal") || lower.hasPrefix("panic") || lower.hasPrefix("traceback")
            || lower.contains("exception") { return .error }
        if lower.hasPrefix("warn") { return .warn }
        return .none
    }
}

/// Byte limits for a log stream (ARCHITECTURE-MAC section 12.3.2). iOS keeps `.unlimited` (behaviour unchanged); the Mac uses
/// `.desktop`: at most 50,000 lines and 16 MB of stored text per stream, and a line over 16 KB is truncated on ingest.
public struct LogLimits: Sendable, Equatable {
    /// Hard maximum of lines per stream (the capacity is clamped to it).
    public var maxLines: Int
    /// Lines longer than this are cut on ingest ("... N bytes truncated").
    public var maxLineBytes: Int
    /// Stored text per stream; the oldest lines are dropped to stay under it.
    public var maxBufferBytes: Int
    /// All streams together; beyond it the oldest lines of non-visible streams are dropped first. 0 = not enforced.
    public var maxTotalBytes: Int

    public init(maxLines: Int, maxLineBytes: Int, maxBufferBytes: Int, maxTotalBytes: Int) {
        self.maxLines = maxLines; self.maxLineBytes = maxLineBytes; self.maxBufferBytes = maxBufferBytes; self.maxTotalBytes = maxTotalBytes
    }

    public static let unlimited = LogLimits(maxLines: 500_000, maxLineBytes: .max, maxBufferBytes: .max, maxTotalBytes: 0)
    public static let desktop = LogLimits(maxLines: 50_000, maxLineBytes: 16 * 1024, maxBufferBytes: 16 * 1024 * 1024, maxTotalBytes: 64 * 1024 * 1024)

    public static var platformDefault: LogLimits {
        #if os(macOS)
        .desktop
        #else
        .unlimited
        #endif
    }

    public var isUnlimited: Bool { self == .unlimited }

    /// Stored size of a line, in bytes of text.
    public static func storedBytes(_ line: LogLine) -> Int {
        line.message.utf8.count + (line.timestamp?.utf8.count ?? 0) + (line.source?.utf8.count ?? 0)
    }

    /// The line with its message cut to `maxLineBytes` (on a character boundary) and a suffix naming how much was dropped.
    public func truncated(_ line: LogLine) -> LogLine {
        guard maxLineBytes != .max else { return line }
        let total = line.message.utf8.count
        guard total > maxLineBytes else { return line }
        var cut = line
        var end = line.message.utf8.index(line.message.utf8.startIndex, offsetBy: maxLineBytes)
        while end > line.message.utf8.startIndex, end.samePosition(in: line.message) == nil { end = line.message.utf8.index(before: end) }
        cut.message = String(line.message[..<end.samePosition(in: line.message)!]) + " \u{2026} \(total - line.message.utf8.distance(from: line.message.utf8.startIndex, to: end)) bytes truncated"
        return cut
    }
}

/// Fixed-capacity FIFO of log lines. Dropping the oldest lines is O(1) amortised. With `limits` it also keeps the stored text under
/// `maxBufferBytes`.
public struct LogRingBuffer: Sendable {
    public let capacity: Int
    public let limits: LogLimits
    private var storage: [LogLine] = []
    private var head = 0
    /// Total lines discarded because of the capacity.
    public private(set) var droppedCount = 0
    /// Bytes of text currently stored (tracked only when `limits` are enforced).
    public private(set) var byteCount = 0

    public init(capacity: Int = 20_000, limits: LogLimits = .unlimited) {
        self.limits = limits
        self.capacity = min(max(1, capacity), limits.maxLines)
    }

    public var count: Int { storage.count - head }
    public var isEmpty: Bool { count == 0 }
    public subscript(i: Int) -> LogLine { storage[head + i] }
    public var lines: ArraySlice<LogLine> { storage[head...] }

    private var tracksBytes: Bool { limits.maxBufferBytes != .max }

    /// Appends; returns how many old lines were dropped by this call.
    @discardableResult
    public mutating func append(contentsOf new: [LogLine]) -> Int {
        storage.append(contentsOf: new)
        if tracksBytes { byteCount += new.reduce(0) { $0 + LogLimits.storedBytes($1) } }
        var dropped = 0
        if count > capacity { dropped = count - capacity }
        if tracksBytes, byteCount - bytes(ofFirst: dropped) > limits.maxBufferBytes {
            // Drop whole lines from the front until the text fits (always keeping the newest line).
            var extra = dropped
            var total = byteCount - bytes(ofFirst: dropped)
            while total > limits.maxBufferBytes, count - extra > 1 { total -= LogLimits.storedBytes(storage[head + extra]); extra += 1 }
            dropped = extra
        }
        if dropped > 0 { drop(dropped) }
        return dropped
    }

    private func bytes(ofFirst n: Int) -> Int {
        guard tracksBytes, n > 0 else { return 0 }
        var t = 0
        for i in 0..<min(n, count) { t += LogLimits.storedBytes(storage[head + i]) }
        return t
    }

    private mutating func drop(_ n: Int) {
        if tracksBytes { byteCount -= bytes(ofFirst: n) }
        head += n
        droppedCount += n
        if head > capacity { storage.removeFirst(head); head = 0 }
    }

    /// Keeps only the last `n` lines (memory-pressure trimming). Returns how many were dropped.
    @discardableResult
    public mutating func trim(keepingLast n: Int) -> Int {
        let extra = count - max(0, n)
        guard extra > 0 else { return 0 }
        drop(extra)
        return extra
    }

    public mutating func removeAll() { storage.removeAll(); head = 0; droppedCount = 0; byteCount = 0 }
}
