import Foundation

public struct YAMLToken: Hashable, Sendable {
    public enum Kind: Sendable { case key, string, number, keyword, comment, anchor, punctuation, marker }
    /// UTF-16 offsets into the source text (usable as `NSRange`).
    public var location: Int
    public var length: Int
    public var kind: Kind
    public var nsRange: NSRange { NSRange(location: location, length: length) }
}

/// Fast, line-oriented YAML tokenizer for syntax highlighting. Not a parser: it never fails and tolerates broken input.
public enum YAMLTokenizer {
    private static let keywords: Set<String> = ["true", "false", "null", "~", "True", "False", "TRUE", "FALSE", "Null", "NULL", "yes", "no", "Yes", "No", "on", "off", "On", "Off"]

    public static func tokens(in text: String) -> [YAMLToken] {
        var tokens: [YAMLToken] = []
        var lineStart = 0
        var blockParent: Int?   // indent of the key owning an open block scalar (| or >)

        var iterator = text.utf16.makeIterator()
        var line: [UInt16] = []
        var finished = false
        while !finished {
            line.removeAll(keepingCapacity: true)
            var hitNewline = false
            while let u = iterator.next() {
                if u == 10 { hitNewline = true; break }
                line.append(u)
            }
            if !hitNewline { finished = true }
            tokenizeLine(line, base: lineStart, blockParent: &blockParent, into: &tokens)
            lineStart += line.count + 1
        }
        return tokens
    }

    // MARK: - Line

    private static let space: UInt16 = 32, tab: UInt16 = 9, hash: UInt16 = 35, dash: UInt16 = 45, colon: UInt16 = 58
    private static let dq: UInt16 = 34, sq: UInt16 = 39, backslash: UInt16 = 92

    private static func tokenizeLine(_ l: [UInt16], base: Int, blockParent: inout Int?, into out: inout [YAMLToken]) {
        let n = l.count
        var indent = 0
        while indent < n, l[indent] == space || l[indent] == tab { indent += 1 }
        let blank = indent >= n || (l[n - 1] == 13 && indent == n - 1)

        if let parent = blockParent {
            if blank || indent > parent {
                if !blank { out.append(YAMLToken(location: base + indent, length: n - indent, kind: .string)) }
                return
            }
            blockParent = nil
        }
        if blank { return }

        func add(_ s: Int, _ e: Int, _ k: YAMLToken.Kind) { if e > s { out.append(YAMLToken(location: base + s, length: e - s, kind: k)) } }
        func atBoundary(_ i: Int) -> Bool { i >= n || l[i] == space || l[i] == tab || l[i] == 13 }

        var p = indent
        if l[p] == hash { add(p, n, .comment); return }
        if n - p >= 3, (l[p] == dash && l[p + 1] == dash && l[p + 2] == dash) || (l[p] == 46 && l[p + 1] == 46 && l[p + 2] == 46), atBoundary(p + 3) {
            add(p, p + 3, .marker)
            p += 3
            skipSpaces(l, &p)
            if p < n, l[p] == hash { add(p, n, .comment) }
            return
        }

        // Sequence dashes (possibly nested: "- - a")
        while p < n, l[p] == dash, atBoundary(p + 1) {
            add(p, p + 1, .punctuation)
            p += 1
            skipSpaces(l, &p)
        }
        if p >= n { return }
        if l[p] == hash { add(p, n, .comment); return }

        // Key?
        var keyColumn = indent
        if let (keyEnd, colonIdx) = findKey(l, from: p) {
            add(p, keyEnd, .key)
            add(colonIdx, colonIdx + 1, .punctuation)
            keyColumn = p
            p = colonIdx + 1
            skipSpaces(l, &p)
        }
        if p >= n { return }
        if l[p] == hash { add(p, n, .comment); return }

        // Value: anchors / tags first
        while p < n, l[p] == 38 /* & */ || l[p] == 42 /* * */ || l[p] == 33 /* ! */ {
            var e = p + 1
            while e < n, !atBoundary(e) { e += 1 }
            add(p, e, .anchor)
            p = e
            skipSpaces(l, &p)
        }
        if p >= n { return }
        if l[p] == hash { add(p, n, .comment); return }

        // Block scalar header
        if l[p] == 124 /* | */ || l[p] == 62 /* > */ {
            var e = p + 1
            while e < n, !atBoundary(e) { e += 1 }
            add(p, e, .punctuation)
            var c = e
            skipSpaces(l, &c)
            if c < n, l[c] == hash { add(c, n, .comment) }
            blockParent = keyColumn
            return
        }

        // Quoted scalar
        if l[p] == dq || l[p] == sq {
            let q = l[p]
            var e = p + 1
            while e < n {
                if q == dq, l[e] == backslash { e += 2; continue }
                if l[e] == q {
                    if q == sq, e + 1 < n, l[e + 1] == sq { e += 2; continue }
                    break
                }
                e += 1
            }
            e = min(e + 1, n)
            add(p, e, .string)
            var c = e
            skipSpaces(l, &c)
            if c < n, l[c] == hash { add(c, n, .comment) }
            return
        }

        // Plain scalar up to " #"
        var e = p
        var commentAt: Int?
        while e < n {
            if l[e] == hash, e > p, l[e - 1] == space || l[e - 1] == tab { commentAt = e; break }
            e += 1
        }
        var valueEnd = commentAt ?? n
        while valueEnd > p, l[valueEnd - 1] == space || l[valueEnd - 1] == tab || l[valueEnd - 1] == 13 { valueEnd -= 1 }
        if valueEnd > p {
            let s = String(decoding: l[p..<valueEnd], as: UTF16.self)
            if keywords.contains(s) { add(p, valueEnd, .keyword) }
            else if isNumber(s) { add(p, valueEnd, .number) }
            else if l[p] == 123 || l[p] == 91 { highlightFlow(l, p, valueEnd, base: base, into: &out) }
        }
        if let c = commentAt { add(c, n, .comment) }
    }

    private static func skipSpaces(_ l: [UInt16], _ p: inout Int) { while p < l.count, l[p] == space || l[p] == tab { p += 1 } }

    /// Returns (end of key text, index of the colon) when `from` starts a `key:` pair.
    private static func findKey(_ l: [UInt16], from p: Int) -> (Int, Int)? {
        let n = l.count
        guard p < n else { return nil }
        let first = l[p]
        if first == 123 || first == 91 || first == 124 || first == 62 || first == 38 || first == 42 { return nil }  // { [ | > & *
        var i = p
        if first == dq || first == sq {
            i = p + 1
            while i < n {
                if first == dq, l[i] == backslash { i += 2; continue }
                if l[i] == first { break }
                i += 1
            }
            guard i < n else { return nil }
            let end = i + 1
            var c = end
            skipSpaces(l, &c)
            if c < n, l[c] == colon, c + 1 >= n || l[c + 1] == space || l[c + 1] == tab || l[c + 1] == 13 { return (end, c) }
            return nil
        }
        while i < n {
            let u = l[i]
            if u == colon, i + 1 >= n || l[i + 1] == space || l[i + 1] == tab || l[i + 1] == 13 {
                var end = i
                while end > p, l[end - 1] == space { end -= 1 }
                return end > p ? (end, i) : nil
            }
            if u == hash, i > p, l[i - 1] == space { return nil }
            i += 1
        }
        return nil
    }

    private static func isNumber(_ s: String) -> Bool {
        if s.hasPrefix("0x"), Int(s.dropFirst(2), radix: 16) != nil { return true }
        if s.hasPrefix("0o"), Int(s.dropFirst(2), radix: 8) != nil { return true }
        guard let f = s.unicodeScalars.first, "+-.0123456789".unicodeScalars.contains(f) else { return false }
        return Double(s) != nil
    }

    /// Minimal flow-collection colouring: quoted strings and keywords/numbers between punctuation.
    private static func highlightFlow(_ l: [UInt16], _ start: Int, _ end: Int, base: Int, into out: inout [YAMLToken]) {
        var i = start
        while i < end {
            let u = l[i]
            if u == dq || u == sq {
                var e = i + 1
                while e < end, l[e] != u { if u == dq, l[e] == backslash { e += 1 }; e += 1 }
                e = min(e + 1, end)
                out.append(YAMLToken(location: base + i, length: e - i, kind: .string))
                i = e
            } else if "{}[],:".utf16.contains(u) {
                out.append(YAMLToken(location: base + i, length: 1, kind: .punctuation))
                i += 1
            } else if u == space {
                i += 1
            } else {
                var e = i
                while e < end, !"{}[],:".utf16.contains(l[e]), l[e] != space { e += 1 }
                let s = String(decoding: l[i..<e], as: UTF16.self)
                if keywords.contains(s) { out.append(YAMLToken(location: base + i, length: e - i, kind: .keyword)) }
                else if isNumber(s) { out.append(YAMLToken(location: base + i, length: e - i, kind: .number)) }
                i = max(e, i + 1)
            }
        }
    }
}
