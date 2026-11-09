import Foundation
import Yams

/// A problem found in YAML text, positioned by 1-based line/column.
public struct YAMLDiagnostic: Hashable, Sendable, Identifiable {
    public enum Severity: Sendable { case error, warning }
    public var line: Int
    public var column: Int
    public var message: String
    public var severity: Severity
    public var id: String { "\(line):\(column):\(message)" }
    public init(line: Int, column: Int = 1, message: String, severity: Severity = .error) {
        self.line = line
        self.column = column
        self.message = message
        self.severity = severity
    }
}

/// One `---` separated document of a multi-document YAML stream.
public struct YAMLDocument: Sendable, Identifiable {
    public var index: Int
    /// 1-based line in the full text where this document's text begins.
    public var startLine: Int
    public var text: String
    public var value: JSONValue?
    public var diagnostic: YAMLDiagnostic?
    public var id: Int { index }

    public var kind: String? { value?["kind"]?.stringValue }
    public var apiVersion: String? { value?["apiVersion"]?.stringValue }
    public var name: String? { value?.value(at: "metadata.name")?.stringValue }
    public var namespace: String? { value?.value(at: "metadata.namespace")?.stringValue }
}

/// YAML ⇄ ``JSONValue`` conversion built on Yams, tuned for Kubernetes manifests.
public enum YAMLCodec {
    /// Keys emitted first, in this order, at every level (kubectl-like ordering).
    static let preferredKeyOrder = ["apiVersion", "kind", "metadata", "name", "generateName", "namespace", "labels", "annotations", "spec", "data", "stringData", "type"]

    // MARK: Dump

    /// Renders a value as block-style YAML with Kubernetes-friendly key ordering. Secrets are not treated specially here.
    public static func dump(_ value: JSONValue) -> String {
        let node = makeNode(value)
        let text = (try? Yams.serialize(node: node, indent: 2, width: -1, allowUnicode: true)) ?? value.jsonString(pretty: true)
        return text
    }

    private static func makeNode(_ value: JSONValue) -> Yams.Node {
        switch value {
        case .null: return .scalar(.init("null", Tag(.null)))
        case .bool(let b): return .scalar(.init(b ? "true" : "false", Tag(.bool)))
        case .int(let i): return .scalar(.init(String(i), Tag(.int)))
        case .double(let d):
            if d == d.rounded(), abs(d) < 1e15 { return .scalar(.init(String(Int(d)) + ".0", Tag(.float))) }
            return .scalar(.init(String(d), Tag(.float)))
        case .string(let s):
            var scalar = s.represented()
            if scalar.style == .any, s.contains("\n"), !s.hasSuffix(" "), !s.contains("\r") {
                scalar.style = .literal
            }
            return .scalar(scalar)
        case .array(let items):
            return .sequence(.init(items.map(makeNode), Tag(.seq), items.isEmpty ? .flow : .block))
        case .object(let dict):
            if dict.isEmpty { return .mapping(.init([], Tag(.map), .flow)) }
            let pairs: [(Yams.Node, Yams.Node)] = orderedKeys(dict).map { (Yams.Node.scalar($0.represented()), makeNode(dict[$0] ?? .null)) }
            return .mapping(.init(pairs, Tag(.map), .block))
        }
    }

    static func orderedKeys(_ dict: [String: JSONValue]) -> [String] {
        let preferred = preferredKeyOrder.filter { dict[$0] != nil }
        let rest = dict.keys.filter { !preferredKeyOrder.contains($0) }.sorted()
        return preferred + rest
    }

    // MARK: Parse

    /// Parses a single document. Throws ``YAMLCodecError`` with a position when the text is invalid.
    public static func parse(_ text: String) throws -> JSONValue {
        do {
            guard let node = try Yams.compose(yaml: text) else { return .null }
            return try convert(node)
        } catch let e as YamlError {
            if case .duplicatedKeysInMapping(let duplicates, let context) = e, let key = duplicates.first {
                // Point at the second occurrence of the key at or after the mapping's start.
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                var seen = 0
                for (i, l) in lines.enumerated() where i + 1 >= context.mark.line {
                    let t = l.drop { $0 == " " || $0 == "-" }
                    if t.hasPrefix(key + ":") || t.hasPrefix("\"\(key)\":") { seen += 1; if seen == 2 { throw YAMLCodecError(line: i + 1, column: 1, message: "Duplicate key “\(key)”") } }
                }
                throw YAMLCodecError(line: context.mark.line, column: context.mark.column, message: "Duplicate key “\(key)”")
            }
            throw YAMLCodecError(e)
        }
    }

    /// Splits on `---` lines and parses each non-empty document. Positions in diagnostics are relative to the full text.
    public static func parseDocuments(_ text: String) -> [YAMLDocument] {
        var chunks: [(start: Int, lines: [Substring])] = [(1, [])]
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in all.enumerated() {
            if isSeparator(line) {
                chunks.append((i + 2, []))
            } else {
                chunks[chunks.count - 1].lines.append(line)
            }
        }
        var docs: [YAMLDocument] = []
        for chunk in chunks {
            let body = chunk.lines.joined(separator: "\n")
            let meaningful = chunk.lines.contains { l in
                let t = l.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty && !t.hasPrefix("#")
            }
            guard meaningful else { continue }
            var doc = YAMLDocument(index: docs.count, startLine: chunk.start, text: body)
            do {
                doc.value = try parse(body)
            } catch let e as YAMLCodecError {
                doc.diagnostic = YAMLDiagnostic(line: e.line + chunk.start - 1, column: e.column, message: e.message)
            } catch {
                doc.diagnostic = YAMLDiagnostic(line: chunk.start, message: error.localizedDescription)
            }
            docs.append(doc)
        }
        return docs
    }

    private static func isSeparator(_ line: Substring) -> Bool {
        guard line.hasPrefix("---") else { return false }
        let rest = line.dropFirst(3)
        return rest.isEmpty || rest.first == " " || rest.first == "\t" || rest.first == "\r"
    }

    /// Lint = parse and report the first syntax error (single or multi document).
    public static func lint(_ text: String) -> [YAMLDiagnostic] {
        parseDocuments(text).compactMap(\.diagnostic)
    }

    // MARK: Node → JSONValue

    private static func convert(_ node: Yams.Node) throws -> JSONValue {
        switch node {
        case .scalar(let s):
            let tag = Resolver.default.resolveTag(of: node)
            if tag == .null { return .null }
            if tag == .bool, let b = node.bool { return .bool(b) }
            if tag == .int, let i = node.int { return .int(i) }
            if tag == .float, let d = node.float { return .double(d) }
            return .string(s.string)
        case .sequence(let seq):
            return .array(try seq.map(convert))
        case .mapping(let map):
            var out: [String: JSONValue] = [:]
            for (k, v) in map {
                let key: String
                if let s = k.scalar { key = s.string } else { throw YAMLCodecError(line: k.mark?.line ?? 1, column: k.mark?.column ?? 1, message: "Complex mapping keys are not supported") }
                if out[key] != nil { throw YAMLCodecError(line: k.mark?.line ?? 1, column: k.mark?.column ?? 1, message: "Duplicate key “\(key)”") }
                out[key] = try convert(v)
            }
            return .object(out)
        case .alias:
            throw YAMLCodecError(line: node.mark?.line ?? 1, column: node.mark?.column ?? 1, message: "Aliases are not supported")
        }
    }

    // MARK: Paths → lines

    /// Finds the 1-based line of a field path such as `spec.template.spec.containers[0].image` (or its closest existing parent).
    public static func line(forPath path: String, in text: String) -> Int? {
        guard let root = try? Yams.compose(yaml: text) else { return nil }
        var current: Yams.Node = root
        var best = root.mark?.line
        for seg in segments(of: path) {
            switch seg {
            case .key(let k):
                guard let map = current.mapping else { return best }
                guard let pair = map.first(where: { $0.key.scalar?.string == k }) else { return best }
                best = pair.key.mark?.line ?? best
                current = pair.value
            case .index(let i):
                guard let seq = current.sequence, seq.indices.contains(i) else { return best }
                current = seq[i]
                best = current.mark?.line ?? best
            }
        }
        return best
    }

    enum PathSegment: Equatable { case key(String), index(Int) }

    static func segments(of path: String) -> [PathSegment] {
        var out: [PathSegment] = []
        var buffer = ""
        var chars = path[...]
        func flush() { if !buffer.isEmpty { out.append(.key(buffer)); buffer = "" } }
        while let c = chars.first {
            chars = chars.dropFirst()
            switch c {
            case ".": flush()
            case "[":
                flush()
                var inner = ""
                while let d = chars.first, d != "]" { inner.append(d); chars = chars.dropFirst() }
                chars = chars.dropFirst()
                if let i = Int(inner) { out.append(.index(i)) } else { out.append(.key(inner)) }
            default: buffer.append(c)
            }
        }
        flush()
        return out
    }
}

public struct YAMLCodecError: Error, Sendable, Equatable {
    public var line: Int
    public var column: Int
    public var message: String
    init(line: Int, column: Int, message: String) { self.line = line; self.column = column; self.message = message }

    init(_ e: YamlError) {
        switch e {
        case .scanner(_, let problem, let mark, _), .parser(_, let problem, let mark, _), .composer(_, let problem, let mark, _):
            self.init(line: mark.line, column: mark.column, message: problem.capitalizedFirst)
        case .reader(let problem, _, _, _):
            self.init(line: 1, column: 1, message: problem.capitalizedFirst)
        default:
            self.init(line: 1, column: 1, message: String(describing: e).prefix(160).description)
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
