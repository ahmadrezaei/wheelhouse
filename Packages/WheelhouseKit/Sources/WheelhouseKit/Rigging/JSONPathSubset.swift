import Foundation

/// The JSONPath subset a Rigging pack may use (ARCHITECTURE-MAC section 11): dot paths, `[n]`, `[*]` and one filter form,
/// `[?(@.field=='value')]`. Everything else is rejected when the pack loads, so no expression is ever evaluated that was not
/// parsed into this closed set of steps.
public struct JSONPathSubset: Hashable, Sendable {
    public enum Step: Hashable, Sendable {
        case key(String)
        case index(Int)
        case wildcard
        /// `[?(@.a.b=='v')]`: the items whose field path equals the string.
        case filter(field: [String], equals: String)
    }

    public struct ParseError: Error, Equatable, Sendable, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    public static let maxLength = 256
    public static let maxSteps = 16
    public static let maxResults = 2000

    public let source: String
    public let steps: [Step]

    private static func isIdent(_ c: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c) || c == "_" || c == "-"
    }

    /// Parses `text`. A leading `$` is allowed; a path must have at least one step.
    public init(_ text: String) throws {
        guard !text.isEmpty, text.utf8.count <= Self.maxLength else { throw ParseError(message: "A path must be 1 to \(Self.maxLength) characters.") }
        let chars = Array(text.unicodeScalars)
        var i = 0
        var out: [Step] = []
        if chars.first == "$" { i = 1 }
        func fail(_ why: String) -> ParseError { ParseError(message: "Path “\(text)” is not supported: \(why).") }
        func word(from start: Int, to end: Int) -> String { String(String.UnicodeScalarView(chars[start..<end])) }
        while i < chars.count {
            switch chars[i] {
            case ".":
                i += 1
                let start = i
                while i < chars.count, Self.isIdent(chars[i]) { i += 1 }
                guard i > start else { throw fail("expected a field name after “.”") }
                out.append(.key(word(from: start, to: i)))
            case "[":
                i += 1
                guard i < chars.count else { throw fail("unterminated “[”") }
                if chars[i] == "*" {
                    i += 1
                    guard i < chars.count, chars[i] == "]" else { throw fail("expected “]” after “*”") }
                    i += 1
                    out.append(.wildcard)
                } else if ("0"..."9").contains(chars[i]) {
                    let start = i
                    while i < chars.count, ("0"..."9").contains(chars[i]) { i += 1 }
                    guard i < chars.count, chars[i] == "]", i - start <= 6, let n = Int(word(from: start, to: i)) else { throw fail("bad index") }
                    i += 1
                    out.append(.index(n))
                } else if chars[i] == "?" {
                    i += 1
                    guard i + 1 < chars.count, chars[i] == "(", chars[i + 1] == "@" else { throw fail("a filter must look like [?(@.field=='value')]") }
                    i += 2
                    var field: [String] = []
                    while i < chars.count, chars[i] == "." {
                        i += 1
                        let start = i
                        while i < chars.count, Self.isIdent(chars[i]) { i += 1 }
                        guard i > start else { throw fail("expected a field name in the filter") }
                        field.append(word(from: start, to: i))
                    }
                    guard !field.isEmpty, i + 1 < chars.count, chars[i] == "=", chars[i + 1] == "=" else { throw fail("a filter must compare with ==") }
                    i += 2
                    guard i < chars.count, chars[i] == "'" || chars[i] == "\"" else { throw fail("the filter value must be a quoted string") }
                    let quote = chars[i]
                    i += 1
                    let start = i
                    while i < chars.count, chars[i] != quote, chars[i] != "\\" { i += 1 }
                    guard i < chars.count, chars[i] == quote else { throw fail("the filter value must be closed and cannot contain a backslash") }
                    let value = word(from: start, to: i)
                    i += 1
                    guard i + 1 < chars.count, chars[i] == ")", chars[i + 1] == "]" else { throw fail("a filter must end with )]") }
                    i += 2
                    out.append(.filter(field: field, equals: value))
                } else {
                    throw fail("only [n], [*] and [?(@.field=='value')] are allowed in brackets")
                }
            default:
                // A bare leading field (`status.phase`) is a dot path too.
                guard out.isEmpty, Self.isIdent(chars[i]) else { throw fail("unexpected “\(chars[i])”") }
                let start = i
                while i < chars.count, Self.isIdent(chars[i]) { i += 1 }
                out.append(.key(word(from: start, to: i)))
            }
            guard out.count <= Self.maxSteps else { throw fail("too many steps") }
        }
        guard !out.isEmpty else { throw fail("the path is empty") }
        self.source = text
        self.steps = out
    }

    /// Every value the path selects (empty when nothing matches). Pure: reads `root` and nothing else.
    public func evaluate(_ root: JSONValue) -> [JSONValue] {
        var current = [root]
        for step in steps {
            var next: [JSONValue] = []
            for value in current {
                switch step {
                case .key(let key):
                    if let v = value.objectValue?[key] { next.append(v) }
                case .index(let n):
                    if let a = value.arrayValue, a.indices.contains(n) { next.append(a[n]) }
                case .wildcard:
                    if let a = value.arrayValue { next += a }
                case .filter(let field, let expected):
                    for item in value.arrayValue ?? [] {
                        var cursor: JSONValue? = item
                        for f in field { cursor = cursor?.objectValue?[f] }
                        if cursor?.stringValue == expected { next.append(item) }
                    }
                }
                if next.count > Self.maxResults { return Array(next.prefix(Self.maxResults)) }
            }
            current = next
            if current.isEmpty { return [] }
        }
        return current
    }

    /// The first selected value.
    public func first(in root: JSONValue) -> JSONValue? { evaluate(root).first }

    /// The first selected value as display text: strings as they are, numbers and booleans formatted; objects, arrays and null give nil.
    public func text(in root: JSONValue) -> String? {
        first(in: root).flatMap(Self.scalarText)
    }

    public static func scalarText(_ v: JSONValue) -> String? {
        switch v {
        case .string(let s): s
        case .int(let n): String(n)
        case .double(let d): d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
        case .bool(let b): b ? "true" : "false"
        case .null, .array, .object: nil
        }
    }
}
