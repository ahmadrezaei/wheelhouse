import Foundation

/// Minimal JSON splitter that returns the EXACT bytes of array elements / object members. Used to keep data this build cannot
/// decode (written by a newer app) and write it back byte-for-byte. Every returned slice is validated as JSON.
enum RawJSON {
    /// The elements of a top-level JSON array, or nil when `data` is not a well-formed array.
    static func arrayElements(_ data: Data) -> [Data]? {
        var s = Scanner(bytes: [UInt8](data))
        s.skipSpace()
        guard s.take(UInt8(ascii: "[")) else { return nil }
        var out: [Data] = []
        s.skipSpace()
        if s.take(UInt8(ascii: "]")) { return s.atEnd ? out : nil }
        while true {
            guard let slice = s.value() else { return nil }
            out.append(slice)
            s.skipSpace()
            if s.take(UInt8(ascii: ",")) { continue }
            if s.take(UInt8(ascii: "]")) { break }
            return nil
        }
        return s.atEnd ? out : nil
    }

    /// The members of a top-level JSON object in file order, or nil when `data` is not a well-formed object.
    static func objectMembers(_ data: Data) -> [(key: String, value: Data)]? {
        var s = Scanner(bytes: [UInt8](data))
        s.skipSpace()
        guard s.take(UInt8(ascii: "{")) else { return nil }
        var out: [(String, Data)] = []
        s.skipSpace()
        if s.take(UInt8(ascii: "}")) { return s.atEnd ? out : nil }
        while true {
            s.skipSpace()
            guard let keyBytes = s.value(), keyBytes.first == UInt8(ascii: "\""),
                  let key = try? JSONSerialization.jsonObject(with: keyBytes, options: .fragmentsAllowed) as? String else { return nil }
            s.skipSpace()
            guard s.take(UInt8(ascii: ":")), let value = s.value() else { return nil }
            out.append((key, value))
            s.skipSpace()
            if s.take(UInt8(ascii: ",")) { continue }
            if s.take(UInt8(ascii: "}")) { break }
            return nil
        }
        return s.atEnd ? out : nil
    }

    /// `object[key]` as a string, for reading the id of an element that did not decode.
    static func string(_ key: String, in element: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: element) as? [String: Any])?[key] as? String
    }

    static func date(_ key: String, in element: Data) -> Date? {
        guard let s = string(key, in: element) else { return nil }
        if let d = ISO8601DateFormatter().date(from: s) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    private struct Scanner {
        let bytes: [UInt8]
        var i = 0
        init(bytes: [UInt8]) { self.bytes = bytes }
        var atEnd: Bool { mutating get { skipSpace(); return i == bytes.count } }

        mutating func skipSpace() { while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 } }
        mutating func take(_ b: UInt8) -> Bool {
            guard i < bytes.count, bytes[i] == b else { return false }
            i += 1
            return true
        }

        /// Skips a string literal starting at the opening quote.
        private mutating func skipString() -> Bool {
            i += 1
            while i < bytes.count {
                switch bytes[i] {
                case UInt8(ascii: "\\"): i += 2
                case UInt8(ascii: "\""): i += 1; return true
                default: i += 1
                }
            }
            return false
        }

        /// One JSON value; returns its exact bytes (validated).
        mutating func value() -> Data? {
            skipSpace()
            guard i < bytes.count else { return nil }
            let start = i
            switch bytes[i] {
            case UInt8(ascii: "\""):
                guard skipString() else { return nil }
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                while i < bytes.count {
                    let ch = bytes[i]
                    if ch == UInt8(ascii: "\"") { guard skipString() else { return nil }; continue }
                    if ch == UInt8(ascii: "{") || ch == UInt8(ascii: "[") { depth += 1 }
                    if ch == UInt8(ascii: "}") || ch == UInt8(ascii: "]") { depth -= 1 }
                    i += 1
                    if depth == 0 { break }
                }
                guard depth == 0 else { return nil }
            default:
                while i < bytes.count, ![0x2C, 0x5D, 0x7D, 0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
                guard i > start else { return nil }
            }
            let slice = Data(bytes[start..<i])
            guard (try? JSONSerialization.jsonObject(with: slice, options: .fragmentsAllowed)) != nil else { return nil }
            return slice
        }
    }
}
