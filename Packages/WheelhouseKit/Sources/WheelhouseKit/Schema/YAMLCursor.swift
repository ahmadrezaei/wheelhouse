import Foundation

/// Line starts of a text in UTF-16 units, the unit `NSTextView` and ``YAMLSpan`` columns use.
public struct TextLineTable: Sendable {
    public let starts: [Int]
    public let length: Int

    public init(_ text: String) {
        var starts = [0]
        var i = 0
        for u in text.utf16 {
            i += 1
            if u == 10 { starts.append(i) }
        }
        self.starts = starts
        self.length = i
    }

    public var lineCount: Int { starts.count }

    /// 0-based index of the line containing `offset`.
    public func lineIndex(containing offset: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The UTF-16 offset of a 1-based line and 0-based column, clamped to the text.
    public func offset(line: Int, column: Int) -> Int {
        let i = max(0, min(line - 1, starts.count - 1))
        return min(starts[i] + max(0, column), length)
    }

    public func range(of span: YAMLSpan) -> NSRange {
        let a = offset(line: span.line, column: span.column)
        let b = offset(line: span.endLine, column: span.endColumn)
        return NSRange(location: a, length: max(0, b - a))
    }
}

/// What one line of block YAML says about its place in the document, read by indentation. It works on text that does not parse
/// yet, which is what the editor has while the user is typing.
struct YAMLLineShape {
    var indent = 0
    /// Number of `- ` markers in front of the content.
    var dashes = 0
    /// Indent of the content after the dashes.
    var effectiveIndent = 0
    /// Column (UTF-16) where the content starts.
    var contentColumn = 0
    var content = Substring()
    var key: String?
    /// UTF-16 length of the key as written, quotes included.
    var keyLength = 0
    /// Column just after the colon, when there is a key.
    var valueColumn: Int?
    var value = Substring()

    var isBlankOrComment: Bool { content.isEmpty || content.hasPrefix("#") }

    init(_ line: Substring) {
        var i = line.startIndex
        var col = 0
        func skipSpaces() { while i < line.endIndex, line[i] == " " { i = line.index(after: i); col += 1 } }
        skipSpaces()
        indent = col
        while i < line.endIndex, line[i] == "-" {
            let next = line.index(after: i)
            guard next == line.endIndex || line[next] == " " else { break }
            dashes += 1
            i = next
            col += 1
            skipSpaces()
        }
        effectiveIndent = col
        contentColumn = col
        content = line[i...]
        if content.hasSuffix("\r") { content = content.dropLast() }
        guard !content.isEmpty, !content.hasPrefix("#"), !content.hasPrefix("{"), !content.hasPrefix("[") else { return }
        parseKey()
    }

    private mutating func parseKey() {
        var j = content.startIndex
        if content.first == "\"" || content.first == "'" {
            let quote = content.first!
            j = content.index(after: j)
            while j < content.endIndex, content[j] != quote { j = content.index(after: j) }
            guard j < content.endIndex else { return }
            let k = String(content[content.index(after: content.startIndex)..<j])
            j = content.index(after: j)
            guard j < content.endIndex, content[j] == ":" else { return }
            finish(key: k, colon: j)
            return
        }
        while j < content.endIndex {
            let c = content[j]
            if c == ":" {
                let next = content.index(after: j)
                if next == content.endIndex || content[next] == " " { finish(key: String(content[content.startIndex..<j]), colon: j); return }
            }
            if c == "#", j > content.startIndex, content[content.index(before: j)] == " " { return }
            j = content.index(after: j)
        }
    }

    private mutating func finish(key k: String, colon: Substring.Index) {
        key = k
        keyLength = content[content.startIndex..<colon].utf16.count
        valueColumn = contentColumn + keyLength + 1
        value = content[content.index(after: colon)...].drop { $0 == " " }
    }

    /// `|`, `>` and their modifiers: the following deeper lines are text, not keys.
    var opensBlockScalar: Bool {
        guard let first = value.first, first == "|" || first == ">" else { return false }
        return value.dropFirst().allSatisfy { $0 == "+" || $0 == "-" || $0.isNumber }
    }
}

/// The key path of a position, followed line by line.
struct YAMLIndentPath {
    struct Entry { var indent: Int; var segment: SchemaPathSegment }
    private(set) var stack: [Entry] = []
    private var blockIndent: Int?

    var path: [SchemaPathSegment] { stack.map(\.segment) }

    /// Moves past one full line.
    mutating func advance(_ shape: YAMLLineShape) {
        if let block = blockIndent {
            if shape.content.isEmpty || shape.indent > block { return }
            blockIndent = nil
        }
        guard !shape.isBlankOrComment else { return }
        enter(shape, pushKey: true)
        if shape.key != nil, shape.opensBlockScalar { blockIndent = shape.effectiveIndent }
    }

    /// The structure of a line (pops, list items) without its key: where a new key on this line would live.
    func parent(for shape: YAMLLineShape) -> [SchemaPathSegment] {
        var copy = self
        copy.blockIndent = nil
        copy.enter(shape, pushKey: false)
        return copy.path
    }

    /// Inside a block scalar the cursor is in free text.
    var inBlockScalar: Bool { blockIndent != nil }

    private mutating func enter(_ shape: YAMLLineShape, pushKey: Bool) {
        while let top = stack.last {
            let pop: Bool
            if shape.dashes > 0 { pop = top.indent > shape.indent || (top.indent == shape.indent && top.segment == .item) }
            else { pop = top.indent >= shape.indent }
            if pop { stack.removeLast() } else { break }
        }
        var indent = shape.indent
        for _ in 0..<shape.dashes {
            stack.append(Entry(indent: indent, segment: .item))
            indent += 2
        }
        if pushKey, let key = shape.key { stack.append(Entry(indent: shape.effectiveIndent, segment: .key(key))) }
    }
}

/// Where the cursor is in a YAML stream: which document and kind, the key path of the surrounding block, and whether the user is
/// typing a key or a value.
struct YAMLCursor {
    var apiVersion: String?
    var kind: String?
    var namespace: String?
    /// Path of the block that holds the key being typed (key context) or of the key whose value is being typed (value context).
    var path: [SchemaPathSegment]
    /// The key in front of the cursor in a value context.
    var key: String?
    var isValue: Bool
    /// What has been typed so far for the key or value.
    var prefix: String
    var replaceRange: NSRange
    var siblings: Set<String>
    var inFreeText: Bool
    /// Key of the enclosing mapping (one level up), for reference rules such as `configMapKeyRef.name`.
    var parentKey: String? {
        let container = isValue ? Array(path.dropLast()) : path
        for seg in container.reversed() { if case .key(let k) = seg { return k } }
        return nil
    }

    var gvk: GroupVersionKind? {
        guard let apiVersion, let kind else { return nil }
        return GroupVersionKind(apiVersion: apiVersion, kind: kind)
    }

    /// `offset` is a UTF-16 offset into `text`.
    static func make(text: String, offset: Int) -> YAMLCursor {
        let table = TextLineTable(text)
        let lines = text.yamlLines
        let cursorLine = min(table.lineIndex(containing: offset), max(0, lines.count - 1))
        let col = offset - table.starts[cursorLine]

        // The document around the cursor.
        var first = 0
        var i = cursorLine - 1
        while i >= 0 { if isSeparator(lines[i]) { first = i + 1; break }; i -= 1 }
        var last = lines.count - 1
        i = cursorLine + 1
        while i < lines.count { if isSeparator(lines[i]) { last = i - 1; break }; i += 1 }

        var apiVersion: String?, kind: String?, namespace: String?
        var path = YAMLIndentPath()
        var inMetadata = false
        for n in first...max(first, last) where n < lines.count {
            let shape = YAMLLineShape(lines[n])
            if !shape.isBlankOrComment, shape.indent == 0, shape.dashes == 0 {
                inMetadata = shape.key == "metadata"
                if shape.key == "apiVersion" { apiVersion = unquote(shape.value) }
                if shape.key == "kind" { kind = unquote(shape.value) }
            } else if inMetadata, shape.indent > 0, shape.key == "namespace", shape.dashes == 0 { namespace = unquote(shape.value) }
            if n < cursorLine { path.advance(shape) }
        }

        let lineText = lines.indices.contains(cursorLine) ? lines[cursorLine] : Substring()
        let before = Substring(utf16Prefix(lineText, col))
        let shape = YAMLLineShape(before)
        let inFree = path.inBlockScalar
        var cursor = YAMLCursor(apiVersion: apiVersion, kind: kind, namespace: namespace, path: [], key: nil, isValue: false, prefix: "",
                                replaceRange: NSRange(location: offset, length: 0), siblings: [], inFreeText: inFree)
        let parent = path.parent(for: shape)
        if let key = shape.key, let valueColumn = shape.valueColumn, col >= valueColumn {
            var typed = shape.value
            if typed.first == "\"" || typed.first == "'" { typed = typed.dropFirst() }
            cursor.isValue = true
            cursor.key = key
            cursor.path = parent + [.key(key)]
            cursor.prefix = String(typed)
            cursor.replaceRange = NSRange(location: offset - typed.utf16.count, length: typed.utf16.count)
        } else {
            let typed = shape.content.hasPrefix("#") ? Substring() : shape.content
            cursor.path = parent
            cursor.prefix = String(typed)
            cursor.replaceRange = NSRange(location: offset - typed.utf16.count, length: typed.utf16.count)
        }
        cursor.siblings = siblingKeys(lines: lines, around: cursorLine, indent: shape.effectiveIndent, first: first, last: last, isKeyContext: !cursor.isValue)
        return cursor
    }

    private static func isSeparator(_ line: Substring) -> Bool {
        guard line.hasPrefix("---") else { return false }
        let rest = line.dropFirst(3)
        return rest.isEmpty || rest.first == " " || rest.first == "\t" || rest.first == "\r"
    }

    private static func unquote(_ s: Substring) -> String {
        var v = s
        if let hash = v.range(of: " #") { v = v[..<hash.lowerBound] }
        let t = v.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, let f = t.first, f == "\"" || f == "'", t.last == f { return String(t.dropFirst().dropLast()) }
        return t
    }

    /// Keys already written in the block the cursor line belongs to (same indent, contiguous).
    private static func siblingKeys(lines: [Substring], around line: Int, indent: Int, first: Int, last: Int, isKeyContext: Bool) -> Set<String> {
        guard isKeyContext else { return [] }
        var out: Set<String> = []
        var n = line - 1
        while n >= first {
            let s = YAMLLineShape(lines[n])
            if s.isBlankOrComment { n -= 1; continue }
            if s.effectiveIndent < indent && !(s.dashes > 0 && s.effectiveIndent == indent) && s.indent < indent { break }
            if s.effectiveIndent == indent, let k = s.key { out.insert(k) }
            if s.dashes > 0, s.effectiveIndent == indent { break }
            if s.indent < indent, s.dashes == 0 { break }
            n -= 1
        }
        n = line + 1
        while n <= last, n < lines.count {
            let s = YAMLLineShape(lines[n])
            if s.isBlankOrComment { n += 1; continue }
            if s.indent < indent { break }
            if s.dashes > 0, s.indent == indent - 2 { break }
            if s.effectiveIndent == indent, s.dashes == 0, let k = s.key { out.insert(k) }
            n += 1
        }
        return out
    }
}

/// The first `count` UTF-16 units of `s` (clamped; a split surrogate pair is dropped).
private func utf16Prefix(_ s: Substring, _ count: Int) -> String {
    let units = s.utf16
    let end = units.index(units.startIndex, offsetBy: max(0, min(count, units.count)))
    return String(s[..<(String.Index(end, within: s) ?? s.startIndex)])
}
