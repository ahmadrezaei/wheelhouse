#if os(macOS)
import Foundation

/// A parsed Compass field (DESIGN-MAC section 9). Parsing never runs anything: `!` and `?` only carry the text the person typed.
public struct CompassQuery: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case all
        /// `>`: menu commands only.
        case actions
        /// `go deploy` or ⇧⌘K: pick a kind.
        case goToKind
        /// `? question`.
        case ask
        /// `!command`: the exact text typed after the bang.
        case run
        case settings
        case station
        case cve
    }

    public var mode: Mode = .all
    /// Free text tokens (lower-cased later by the matcher).
    public var tokens: [String] = []
    /// The text after a mode prefix, as typed (`!` keeps it exactly).
    public var argument = ""
    public var cluster: String?
    public var namespace: String?
    public var labelSelector: String?
    public var image: String?
    public var states: [String] = []

    public init() {}

    public var isEmpty: Bool { mode == .all && tokens.isEmpty && cluster == nil && namespace == nil && labelSelector == nil && image == nil && states.isEmpty }

    public static func parse(_ raw: String) -> CompassQuery {
        var q = CompassQuery()
        let trimmedLeading = raw.drop(while: { $0 == " " })
        if trimmedLeading.hasPrefix("!") { q.mode = .run; q.argument = String(trimmedLeading.dropFirst()); return q }
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix(">") { q.mode = .actions; q.argument = String(text.dropFirst()).trimmingCharacters(in: .whitespaces); q.tokens = words(q.argument); return q }
        if text.hasPrefix("?") { q.mode = .ask; q.argument = String(text.dropFirst()).trimmingCharacters(in: .whitespaces); return q }
        let lower = text.lowercased()
        for (prefix, mode) in [("settings:", Mode.settings), ("station:", .station), ("cve:", .cve)] where lower.hasPrefix(prefix) {
            q.mode = mode
            q.argument = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            q.tokens = words(q.argument)
            return q
        }
        if lower == "go" || lower.hasPrefix("go ") {
            q.mode = .goToKind
            q.argument = String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            q.tokens = words(q.argument)
            return q
        }
        let parts = words(text)
        var next = 0
        while next < parts.count {
            var token = parts[next]
            next += 1
            let t = token.lowercased()
            // A selector may hold spaces: `l:app=web,tier in (api, worker)` is one field.
            if t.hasPrefix("l:") {
                while next < parts.count, ["in", "notin"].contains(parts[next].lowercased()) || parts[next].hasPrefix("(") || token.hasSuffix(",") {
                    token += " " + parts[next]
                    next += 1
                }
            }
            if token.hasPrefix("@"), token.count > 1 { q.cluster = String(token.dropFirst()) }
            else if token.hasPrefix("#"), token.count > 1 { q.namespace = String(token.dropFirst()) }
            else if t.hasPrefix("ns:"), token.count > 3 { q.namespace = String(token.dropFirst(3)) }
            else if t.hasPrefix("l:"), token.count > 2 { q.labelSelector = String(token.dropFirst(2)) }
            else if t.hasPrefix("img:"), token.count > 4 { q.image = String(token.dropFirst(4)) }
            else if t.hasPrefix("is:"), token.count > 3 { q.states.append(String(t.dropFirst(3))) }
            else { q.tokens.append(token) }
        }
        return q
    }

    /// `l:app=web,tier in (api,worker)` has spaces inside parentheses: keep a selector in one piece.
    private static func words(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var depth = 0
        for ch in s {
            if ch == "(" { depth += 1 } else if ch == ")" { depth = max(0, depth - 1) }
            if ch == " " && depth == 0 { if !current.isEmpty { out.append(current); current = "" } } else { current.append(ch) }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

/// A label selector in the subset Compass accepts: `k=v`, `k==v`, `k!=v`, `k`, `!k`, `k in (a,b)`, `k notin (a,b)`, comma separated.
/// A selector that does not validate matches nothing and reports `isValid == false` (the field shows it).
public struct CompassLabelSelector: Sendable {
    enum Requirement: Sendable {
        case equals(String, String), notEquals(String, String), exists(String), absent(String), isIn(String, Set<String>), notIn(String, Set<String>)
    }
    let requirements: [Requirement]
    public let isValid: Bool
    /// `k=v` byte strings when every requirement is an equality: such a selector is answered by a byte search on the folded labels.
    let equalities: [[UInt8]]?

    public init(_ text: String) {
        var reqs: [Requirement] = []
        var valid = true
        var depth = 0
        var pieces: [String] = []
        var current = ""
        for ch in text {
            if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 }
            if ch == "," && depth == 0 { pieces.append(current); current = "" } else { current.append(ch) }
        }
        pieces.append(current)
        for raw in pieces {
            let piece = raw.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { valid = false; continue }
            if let r = piece.range(of: " notin ") ?? piece.range(of: " notin("), let set = Self.set(piece, after: r) {
                reqs.append(.notIn(String(piece[..<r.lowerBound]).trimmingCharacters(in: .whitespaces), set))
            } else if let r = piece.range(of: " in ") ?? piece.range(of: " in("), let set = Self.set(piece, after: r) {
                reqs.append(.isIn(String(piece[..<r.lowerBound]).trimmingCharacters(in: .whitespaces), set))
            } else if let r = piece.range(of: "!=") {
                reqs.append(.notEquals(String(piece[..<r.lowerBound]), String(piece[r.upperBound...])))
            } else if let r = piece.range(of: "==") ?? piece.range(of: "=") {
                reqs.append(.equals(String(piece[..<r.lowerBound]), String(piece[r.upperBound...])))
            } else if piece.hasPrefix("!"), piece.count > 1 {
                reqs.append(.absent(String(piece.dropFirst())))
            } else if piece.allSatisfy({ $0.isLetter || $0.isNumber || "-_./".contains($0) }) {
                reqs.append(.exists(piece))
            } else { valid = false }
        }
        requirements = reqs
        isValid = valid && !reqs.isEmpty
        let pairs: [[UInt8]] = reqs.compactMap { if case .equals(let k, let v) = $0 { return Array("\(k)=\(v)".utf8) } else { return nil } }
        equalities = pairs.count == reqs.count && !pairs.isEmpty ? pairs : nil
    }

    private static func set(_ piece: String, after r: Range<String.Index>) -> Set<String>? {
        let rest = piece[r.upperBound...].trimmingCharacters(in: .whitespaces)
        let body = piece[r].hasSuffix("(") ? "(" + rest : rest
        guard body.hasPrefix("("), body.hasSuffix(")") else { return nil }
        return Set(body.dropFirst().dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    public func matches(_ labels: [String: String]) -> Bool {
        guard isValid else { return false }
        return requirements.allSatisfy { r in
            switch r {
            case .equals(let k, let v): labels[k] == v
            case .notEquals(let k, let v): labels[k] != v
            case .exists(let k): labels[k] != nil
            case .absent(let k): labels[k] == nil
            case .isIn(let k, let vs): labels[k].map(vs.contains) ?? false
            case .notIn(let k, let vs): labels[k].map { !vs.contains($0) } ?? true
            }
        }
    }
}
#endif
