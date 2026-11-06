import Foundation

/// Re-applies the user's edits (`base` → `edited`) on top of a newer server copy (`latest`).
/// Used after a 409 / resourceVersion mismatch ("Rebase my edits").
public enum YAMLRebase {
    public struct Result: Sendable {
        public var merged: JSONValue
        /// Dotted paths changed both by the user and on the server to different values; the user's value wins.
        public var conflicts: [String]
        public var appliedPaths: [String]
    }

    public static func rebase(base: JSONValue, edited: JSONValue, onto latest: JSONValue) -> Result {
        var conflicts: [String] = []
        var applied: [String] = []
        let merged = merge(base: base, edited: edited, latest: latest, path: "", conflicts: &conflicts, applied: &applied)
        return Result(merged: merged ?? .null, conflicts: conflicts, appliedPaths: applied)
    }

    /// nil = remove the key.
    private static func merge(base: JSONValue?, edited: JSONValue?, latest: JSONValue?, path: String, conflicts: inout [String], applied: inout [String]) -> JSONValue? {
        if edited == base { return latest }  // user didn't touch it
        if let e = edited?.objectValue, let l = latest?.objectValue, base == nil || base?.objectValue != nil {
            let b = base?.objectValue ?? [:]
            var out: [String: JSONValue] = [:]
            let keys = Set(e.keys).union(l.keys).union(b.keys)
            for k in keys {
                let childPath = path.isEmpty ? k : "\(path).\(k)"
                if let v = merge(base: b[k], edited: e[k], latest: l[k], path: childPath, conflicts: &conflicts, applied: &applied) { out[k] = v }
            }
            return .object(out)
        }
        // Leaf (or type change / array): the user's version wins; record a conflict if the server also changed it.
        if latest != base, latest != edited { conflicts.append(path) }
        applied.append(path)
        return edited
    }
}
