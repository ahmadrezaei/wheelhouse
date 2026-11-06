import Foundation

public struct DiffLine: Hashable, Sendable, Identifiable {
    public enum Kind: Sendable { case context, added, removed }
    public var kind: Kind
    public var text: String
    public var oldNumber: Int?
    public var newNumber: Int?
    /// Position in the full diff (stable id).
    public var id: Int
}

/// One displayed row of a (possibly folded) diff.
public enum DiffRow: Hashable, Sendable, Identifiable {
    case line(DiffLine)
    /// `count` unchanged lines hidden; `id` identifies the fold so it can be expanded.
    case fold(id: Int, count: Int)

    public var id: String {
        switch self {
        case .line(let l): "l\(l.id)"
        case .fold(let id, _): "f\(id)"
        }
    }
}

/// Line-based diff (Myers O(ND)) with context folding.
public enum LineDiff {
    public struct Stats: Hashable, Sendable {
        public var added: Int
        public var removed: Int
        public var total: Int { added + removed }
        public init(added: Int, removed: Int) { self.added = added; self.removed = removed }
    }

    public static func lines(_ text: String) -> [String] {
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    public static func diff(old: String, new: String) -> [DiffLine] { diff(old: lines(old), new: lines(new)) }

    public static func diff(old a: [String], new b: [String]) -> [DiffLine] {
        // Trim common prefix / suffix to keep the core small.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let ma = Array(a[prefix..<(a.count - suffix)])
        let mb = Array(b[prefix..<(b.count - suffix)])
        let ops = myers(ma, mb)

        var out: [DiffLine] = []
        var o = 1, n = 1
        func add(_ kind: DiffLine.Kind, _ text: String) {
            switch kind {
            case .context: out.append(DiffLine(kind: .context, text: text, oldNumber: o, newNumber: n, id: out.count)); o += 1; n += 1
            case .removed: out.append(DiffLine(kind: .removed, text: text, oldNumber: o, newNumber: nil, id: out.count)); o += 1
            case .added: out.append(DiffLine(kind: .added, text: text, oldNumber: nil, newNumber: n, id: out.count)); n += 1
            }
        }
        for i in 0..<prefix { add(.context, a[i]) }
        var ia = 0, ib = 0
        for op in ops {
            switch op {
            case .equal: add(.context, ma[ia]); ia += 1; ib += 1
            case .delete: add(.removed, ma[ia]); ia += 1
            case .insert: add(.added, mb[ib]); ib += 1
            }
        }
        for i in 0..<suffix { add(.context, a[a.count - suffix + i]) }
        return out
    }

    public static func stats(_ lines: [DiffLine]) -> Stats {
        Stats(added: lines.lazy.filter { $0.kind == .added }.count, removed: lines.lazy.filter { $0.kind == .removed }.count)
    }

    /// Hides runs of unchanged lines longer than `2 * context` (+ a minimum fold size), keeping `context` lines around changes.
    /// Folds whose id is in `expanded` are shown in full.
    public static func fold(_ lines: [DiffLine], context: Int = 3, expanded: Set<Int> = []) -> [DiffRow] {
        guard lines.contains(where: { $0.kind != .context }) else {
            return lines.isEmpty ? [] : [.fold(id: 0, count: lines.count)]
        }
        var keep = [Bool](repeating: false, count: lines.count)
        for (i, l) in lines.enumerated() where l.kind != .context {
            for j in max(0, i - context)...min(lines.count - 1, i + context) { keep[j] = true }
        }
        var rows: [DiffRow] = []
        var i = 0
        while i < lines.count {
            if keep[i] { rows.append(.line(lines[i])); i += 1; continue }
            var j = i
            while j < lines.count, !keep[j] { j += 1 }
            let count = j - i
            if count < 2 || expanded.contains(lines[i].id) {
                for k in i..<j { rows.append(.line(lines[k])) }
            } else {
                rows.append(.fold(id: lines[i].id, count: count))
            }
            i = j
        }
        return rows
    }

    // MARK: Myers

    /// Beyond this many edits the diff degrades to delete-all / insert-all (keeps memory bounded).
    static let maxEditDistance = 2000

    enum Op { case equal, delete, insert }

    static func myers(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        if n == 0 { return Array(repeating: .insert, count: m) }
        if m == 0 { return Array(repeating: .delete, count: n) }
        let maxD = n + m
        let offset = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 4)
        var trace: [[Int]] = []
        var found = false
        outer: for d in 0...min(maxD, maxEditDistance) {
            trace.append(Array(v[(offset - d - 1)...(offset + d + 1)]))
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) { x = v[offset + k + 1] } else { x = v[offset + k - 1] + 1 }
                var y = x - k
                while x < n, y < m, a[x] == b[y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n, y >= m { found = true; break outer }
                k += 2
            }
        }
        guard found else { return Array(repeating: .delete, count: n) + Array(repeating: .insert, count: m) }
        // Backtrack.
        var ops: [Op] = []
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let vv = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && vv[k - 1 + d + 1] < vv[k + 1 + d + 1]) { prevK = k + 1 } else { prevK = k - 1 }
            let prevX = vv[prevK + d + 1]
            let prevY = prevX - prevK
            while x > prevX, y > prevY { ops.append(.equal); x -= 1; y -= 1 }
            if d > 0 {
                if x == prevX { ops.append(.insert) } else { ops.append(.delete) }
            }
            x = prevX; y = prevY
        }
        return ops.reversed()
    }
}
