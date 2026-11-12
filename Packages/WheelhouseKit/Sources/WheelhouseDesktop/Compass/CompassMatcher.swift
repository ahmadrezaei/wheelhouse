#if os(macOS)
import Foundation

/// Name matching for Compass (ARCHITECTURE-MAC section 12.4): exact, prefix, word prefix, substring, an acronym or word-prefix chain
/// (`pa-api` finds `payments-api`, `pgw` finds `payments-gateway-worker`) and a subsequence, all over lower-cased UTF-8 bytes so the
/// scan of 100,000 names allocates nothing. Higher is better; nil is no match.
public enum CompassMatcher {
    public static let exact = 1_000
    public static let prefix = 900
    public static let wordPrefix = 800
    public static let substring = 700
    public static let chain = 650
    public static let acronym = 600
    public static let subsequence = 300

    /// `-` `.` `_` `/` space and `:`.
    @inline(__always) static func isSeparator(_ b: UInt8) -> Bool { b == 45 || b == 46 || b == 95 || b == 47 || b == 32 || b == 58 }

    /// The lower-cased bytes of a string (ASCII folding only; Kubernetes names are ASCII).
    public static func fold(_ s: String) -> [UInt8] {
        s.utf8.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
    }

    /// Score of the folded query `q` against the folded target `t`.
    public static func score(_ q: [UInt8], in t: [UInt8]) -> Int? {
        t.withUnsafeBufferPointer { score(q, in: $0) }
    }

    public static func score(_ q: [UInt8], in t: UnsafeBufferPointer<UInt8>) -> Int? {
        let m = q.count, n = t.count
        guard m > 0, m <= n else { return nil }
        var i = 0
        while i < m, t[i] == q[i] { i += 1 }
        if i == m { return m == n ? exact : prefix - min(n - m, 90) }
        // Substring (first occurrence): a word start beats the middle of a word.
        let first = q[0]
        var start = 1
        while start + m <= n {
            if t[start] == first {
                var j = 1
                while j < m, t[start + j] == q[j] { j += 1 }
                if j == m { return (isSeparator(t[start - 1]) ? wordPrefix : substring) - min(start, 90) }
            }
            start += 1
        }
        if let s = chainScore(q, t) { return s }
        return subsequenceScore(q, t)
    }

    /// `pa-api`: every separator-delimited part of the query is a prefix of a later word, in order. `pgw`: the characters are the
    /// initials of words, in order. No allocation: this runs for every name that is not a prefix or a substring match.
    private static func chainScore(_ q: [UInt8], _ t: UnsafeBufferPointer<UInt8>) -> Int? {
        let n = t.count
        @inline(__always) func isWordStart(_ k: Int) -> Bool { !isSeparator(t[k]) && (k == 0 || isSeparator(t[k - 1])) }
        if q.contains(where: isSeparator) {
            var cursor = 0
            var partStart = 0
            var parts = 0
            var chained = true
            var k = 0
            while k <= q.count, chained {
                if k == q.count || isSeparator(q[k]) {
                    if k > partStart {
                        parts += 1
                        let length = k - partStart
                        var found = false
                        var w = cursor
                        while w + length <= n {
                            if isWordStart(w) {
                                var j = 0
                                while j < length, t[w + j] == q[partStart + j] { j += 1 }
                                if j == length { found = true; cursor = w + 1; break }
                            }
                            w += 1
                        }
                        if !found { chained = false }
                    }
                    partStart = k + 1
                }
                k += 1
            }
            if chained, parts > 1 { return chain }
        }
        var cursor = 0
        var words = 0
        for c in q where !isSeparator(c) {
            var found = false
            while cursor < n {
                let k = cursor
                cursor += 1
                if t[k] == c, isWordStart(k) { found = true; words += 1; break }
            }
            if !found { return nil }
        }
        return words > 1 ? acronym : nil
    }

    private static func subsequenceScore(_ q: [UInt8], _ t: UnsafeBufferPointer<UInt8>) -> Int? {
        var qi = 0
        var span = 0
        var firstAt = -1
        for (k, c) in t.enumerated() where qi < q.count && c == q[qi] {
            if firstAt < 0 { firstAt = k }
            qi += 1
            span = k - firstAt
        }
        return qi == q.count ? subsequence - min(max(span - q.count, 0), 250) : nil
    }

    /// The same match as ``matchedOffsets(query:in:)`` as offsets of `Character`s of `name`, which is what a rendering needs (a name
    /// with a multi-byte character such as "…" has fewer characters than UTF-8 bytes).
    public static func matchedCharacterOffsets(query: String, in name: String) -> Set<Int> {
        let bytes = Set(matchedOffsets(query: query, in: name))
        guard !bytes.isEmpty else { return [] }
        var out = Set<Int>()
        var start = 0
        for (i, ch) in name.enumerated() {
            let width = String(ch).utf8.count
            if (start..<(start + width)).contains(where: bytes.contains) { out.insert(i) }
            start += width
        }
        return out
    }

    /// Offsets in `name` of the characters a query matched, for the bold rendering of result rows.
    public static func matchedOffsets(query: String, in name: String) -> [Int] {
        let q = fold(query.trimmingCharacters(in: .whitespaces)), t = fold(name)
        guard !q.isEmpty, q.count <= t.count else { return [] }
        for start in 0...(t.count - q.count) where Array(t[start..<(start + q.count)]) == q { return Array(start..<(start + q.count)) }
        var out: [Int] = []
        var qi = 0
        for (k, c) in t.enumerated() where qi < q.count && c == q[qi] { out.append(k); qi += 1 }
        return qi == q.count ? out : []
    }
}
#endif
