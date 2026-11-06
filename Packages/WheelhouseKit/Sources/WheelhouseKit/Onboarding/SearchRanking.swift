import Foundation

/// Name matching used by Search: exact > prefix > word-prefix > substring > subsequence.
public enum SearchRanking {
    /// Lower is better; nil = no match.
    public static func score(name: String, query: String) -> Int? {
        let n = name.lowercased(), q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        if n == q { return 0 }
        if n.hasPrefix(q) { return 1 }
        if n.split(whereSeparator: { "-._/ ".contains($0) }).contains(where: { $0.hasPrefix(q) }) { return 2 }
        if n.contains(q) { return 3 }
        var it = n.makeIterator()
        for ch in q { var found = false; while let c = it.next() { if c == ch { found = true; break } }; if !found { return nil } }
        return 4
    }
}
