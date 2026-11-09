import Foundation
import Yams

/// A source range: 1-based lines and 0-based UTF-16 columns, so it maps straight onto an `NSRange` of the editor text.
public struct YAMLSpan: Hashable, Sendable {
    public var line: Int
    public var column: Int
    public var endLine: Int
    public var endColumn: Int
    public init(line: Int, column: Int, endLine: Int, endColumn: Int) {
        self.line = line
        self.column = column
        self.endLine = endLine
        self.endColumn = endColumn
    }
}

/// One `key: value` pair of a mapping with the position of the key.
public struct YAMLEntry: Sendable {
    public var key: String
    public var keySpan: YAMLSpan
    public var value: YAMLNode
}

/// A parsed YAML node that remembers where it came from. Scalars are typed the same way ``YAMLCodec`` types them, so a schema
/// check sees what the server would see.
public struct YAMLNode: Sendable {
    public enum Kind: Sendable { case mapping, sequence, scalar }
    public var kind: Kind
    public var span: YAMLSpan
    /// The typed value of a scalar (`.null`, `.bool`, `.int`, `.double`, `.string`); `.null` for collections.
    public var scalar: JSONValue = .null
    /// `true` when the scalar was written in quotes (so it is always a string).
    public var isQuoted = false
    /// `true` for an alias (`*name`), which the schema checks skip.
    public var isOpaque = false
    public var entries: [YAMLEntry] = []
    public var items: [YAMLNode] = []

    public func entry(_ key: String) -> YAMLEntry? { entries.first { $0.key == key } }
    public func child(_ key: String) -> YAMLNode? { entry(key)?.value }

    /// The node as a plain value (used for `enum`, `const` and reference checks).
    public var value: JSONValue {
        switch kind {
        case .scalar: scalar
        case .sequence: .array(items.map(\.value))
        case .mapping: .object(Dictionary(entries.map { ($0.key, $0.value.value) }, uniquingKeysWith: { a, _ in a }))
        }
    }
}

/// One document of a stream with positions.
public struct YAMLMapDocument: Sendable, Identifiable {
    public var index: Int
    /// 1-based line in the full text of the document's first line.
    public var startLine: Int
    /// Last line of the document's text (inclusive).
    public var endLine: Int
    public var root: YAMLNode?
    public var diagnostic: YAMLDiagnostic?
    public var id: Int { index }

    public var apiVersion: String? { root?.child("apiVersion")?.scalar.stringValue }
    public var kind: String? { root?.child("kind")?.scalar.stringValue }
    public var name: String? { root?.child("metadata")?.child("name")?.scalar.stringValue }
    public var namespace: String? { root?.child("metadata")?.child("namespace")?.scalar.stringValue }
}

/// Builds position-carrying trees for every document of a YAML stream. Document splitting and numbering are
/// ``YAMLCodec/parseDocuments(_:)``'s, so indices and start lines agree with the rest of the editor.
public enum YAMLNodeMap {
    public static func documents(in text: String) -> [YAMLMapDocument] {
        YAMLCodec.chunks(of: text).enumerated().map { index, chunk in
            let lineCount = chunk.text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            var doc = YAMLMapDocument(index: index, startLine: chunk.start, endLine: chunk.start + lineCount - 1)
            do {
                guard let node = try Yams.compose(yaml: chunk.text) else { return doc }
                var converter = Converter(text: chunk.text, firstLine: chunk.start)
                doc.root = converter.convert(node)
            } catch {
                // Reuse the codec's diagnostics so duplicate keys and syntax errors read the same everywhere.
                do { _ = try YAMLCodec.parse(chunk.text) } catch let e as YAMLCodecError {
                    doc.diagnostic = YAMLDiagnostic(line: e.line + chunk.start - 1, column: e.column, message: e.message)
                } catch {
                    doc.diagnostic = YAMLDiagnostic(line: chunk.start, message: error.localizedDescription)
                }
            }
            return doc
        }
    }

    // MARK: Conversion

    private struct Converter {
        let lines: [Substring]
        let firstLine: Int

        init(text: String, firstLine: Int) {
            self.lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            self.firstLine = firstLine
        }

        /// Yams columns count Unicode scalars; the editor counts UTF-16 units.
        func utf16Column(line: Int, scalarColumn: Int) -> Int {
            let index = line - 1
            guard index >= 0, index < lines.count else { return max(0, scalarColumn - 1) }
            let l = lines[index]
            if l.utf8.count == l.unicodeScalars.count { return max(0, scalarColumn - 1) }
            var units = 0
            for (i, s) in l.unicodeScalars.enumerated() {
                if i >= scalarColumn - 1 { break }
                units += s.utf16.count
            }
            return units
        }

        func lineLength(_ line: Int) -> Int {
            let index = line - 1
            guard index >= 0, index < lines.count else { return 0 }
            var l = lines[index]
            if l.last == "\r" { l = l.dropLast() }
            return l.utf16.count
        }

        func start(of node: Yams.Node) -> (line: Int, column: Int) {
            guard let mark = node.mark else { return (1, 0) }
            return (mark.line, utf16Column(line: mark.line, scalarColumn: mark.column))
        }

        func scalarSpan(_ s: Yams.Node.Scalar, at start: (line: Int, column: Int)) -> YAMLSpan {
            var length = s.string.utf16.count
            switch s.style {
            case .singleQuoted, .doubleQuoted: length += 2
            case .literal, .folded: length = 1
            default: break
            }
            if s.string.contains("\n") && s.style != .literal && s.style != .folded { length = max(0, lineLength(start.line) - start.column) }
            let end = min(start.column + length, max(lineLength(start.line), start.column))
            return YAMLSpan(line: start.line + firstLine - 1, column: start.column, endLine: start.line + firstLine - 1, endColumn: end)
        }

        mutating func convert(_ node: Yams.Node) -> YAMLNode {
            let at = start(of: node)
            let line = at.line + firstLine - 1
            switch node {
            case .scalar(let s):
                var out = YAMLNode(kind: .scalar, span: scalarSpan(s, at: at))
                let tag = Resolver.default.resolveTag(of: node)
                switch s.style {
                case .singleQuoted, .doubleQuoted:
                    out.scalar = .string(s.string)
                    out.isQuoted = true
                default:
                    if tag == .null { out.scalar = .null }
                    else if tag == .bool, let b = node.bool { out.scalar = .bool(b) }
                    else if tag == .int, let i = node.int { out.scalar = .int(i) }
                    else if tag == .float, let d = node.float { out.scalar = .double(d) }
                    else { out.scalar = .string(s.string) }
                }
                return out
            case .sequence(let seq):
                var out = YAMLNode(kind: .sequence, span: YAMLSpan(line: line, column: at.column, endLine: line, endColumn: at.column))
                out.items = seq.map { convert($0) }
                if let last = out.items.last { out.span.endLine = last.span.endLine; out.span.endColumn = last.span.endColumn }
                return out
            case .mapping(let map):
                var out = YAMLNode(kind: .mapping, span: YAMLSpan(line: line, column: at.column, endLine: line, endColumn: at.column))
                for (k, v) in map {
                    let ks = k.scalar.map { $0.string } ?? ""
                    let kn = convert(k)
                    out.entries.append(YAMLEntry(key: ks, keySpan: kn.span, value: convert(v)))
                }
                if let last = out.entries.last { out.span.endLine = last.value.span.endLine; out.span.endColumn = last.value.span.endColumn }
                return out
            case .alias:
                var out = YAMLNode(kind: .scalar, span: YAMLSpan(line: line, column: at.column, endLine: line, endColumn: at.column + 1))
                out.scalar = .null
                out.isOpaque = true
                return out
            }
        }
    }
}
