import Foundation

/// The result of one tool call: redacted, capped JSON, ready to go into a `tool_result` or an MCP result.
public struct ToolOutput: Sendable, Equatable, Error {
    public var json: JSONValue
    public var isError: Bool
    /// Set when the cluster needs the user's permission (First Mate, Production on Ask). The app shows the Allow prompt.
    public var permissionRequired: ClusterID?

    public init(json: JSONValue, isError: Bool = false, permissionRequired: ClusterID? = nil) {
        self.json = json
        self.isError = isError
        self.permissionRequired = permissionRequired
    }

    public var text: String { json.jsonString() }

    static func error(_ code: String, _ message: String? = nil) -> ToolOutput {
        var json: JSONValue = ["error": .string(code)]
        if let message { json["message"] = .string(message) }
        return ToolOutput(json: json, isError: true)
    }

    static func permissionRequired(_ cluster: ClusterID) -> ToolOutput {
        ToolOutput(json: ["error": "permission_required", "cluster": .string(cluster)], isError: true, permissionRequired: cluster)
    }

    static func unavailable(_ tool: String, _ reason: String) -> ToolOutput {
        ToolOutput(json: ["error": "unavailable", "tool": .string(tool), "reason": .string(reason)], isError: true)
    }
}


/// Caps a result at ``maxBytes`` (48 KB, after redaction) and says so explicitly at the top level: `"truncated": true`,
/// `"omitted"` (list items and object keys dropped) and `"omitted_chars"` (characters cut from strings).
///
/// One pass allocates the byte budget top-down: small values are kept whole, larger ones share what is left equally
/// ("water-filling"), strings are cut to their share, lists keep the elements that fit, and an object with more keys than its
/// budget can hold keeps the first keys in sorted order. Sizes are estimated by a cheap scan; if the estimate was a little low
/// the pass repeats with a smaller budget (at most 8 times).
public enum ToolResultLimiter {
    public static let maxBytes = 48 * 1024
    public static let maxListItems = 500
    public static let maxLogLines = 2_000

    /// A key needs at least this much room to be worth keeping.
    private static let minimumPerKey = 48

    /// `tailKeys` names the fields where the end is the interesting part (log lines): they keep their last elements.
    public static func limit(_ value: JSONValue, maxBytes: Int = maxBytes, tailKeys: Set<String> = ["lines"]) -> JSONValue {
        guard case .object(var base) = value else { return value }
        let startSize = estimate(value)
        // The estimate can undercount a string that is mostly escapes, so anything that might fit is measured for real
        // (a result near the cap is small to encode); only results the estimate already puts over the cap skip this.
        if startSize <= maxBytes + maxBytes / 4, encodedSize(value) <= maxBytes { return value }
        let priorItems = base.removeValue(forKey: "omitted")?.intValue ?? 0
        let priorChars = base.removeValue(forKey: "omitted_chars")?.intValue ?? 0
        base["truncated"] = nil
        var budget = max(maxBytes - 160, 64)
        for _ in 0..<8 {
            var counters = Counters(items: priorItems, chars: priorChars)
            guard case .object(var fitted) = fit(.object(base), size: startSize, budget: budget, key: nil, tailKeys: tailKeys, counters: &counters) else { break }
            fitted["truncated"] = true
            fitted["omitted"] = .int(counters.items)
            if counters.chars > 0 { fitted["omitted_chars"] = .int(counters.chars) }
            let real = encodedSize(.object(fitted))
            if real <= maxBytes { return .object(fitted) }
            // Scale by how far off the estimate was, with margin, so an escape-heavy value converges in a pass or two.
            budget = max(64, min(budget * 9 / 10, budget * maxBytes / real * 9 / 10))
        }
        return ["error": "result_too_large", "truncated": true, "message": "The result does not fit the 48 KB limit even when shortened."]
    }

    private struct Counters { var items: Int; var chars: Int }

    /// `size` is the caller's estimate of `value`, so nothing is scanned twice per level.
    private static func fit(_ value: JSONValue, size: Int, budget: Int, key: String?, tailKeys: Set<String>, counters: inout Counters) -> JSONValue {
        if size <= budget { return value }
        switch value {
        case .string(let s):
            // Cut by UTF-8 bytes (no grapheme counting), backing off to a character boundary.
            var keep = max(0, budget - 2)
            let utf8 = s.utf8
            let fromEnd = tailKeys.contains(key ?? "")
            var text = ""
            while true {
                if let cut = String(fromEnd ? utf8.suffix(keep) : utf8.prefix(keep)) { text = cut; break }
                keep -= 1
            }
            counters.chars += utf8.count - text.utf8.count
            return .string(text)
        case .array(let items):
            let sizes = items.map { estimate($0) + 1 }
            let fromEnd = tailKeys.contains(key ?? "")
            var used = 2
            var kept: [JSONValue] = []
            let order = fromEnd ? Array(items.indices.reversed()) : Array(items.indices)
            for index in order {
                guard used + sizes[index] <= budget else { break }
                used += sizes[index]
                kept.append(items[index])
            }
            if fromEnd { kept.reverse() }
            if kept.isEmpty, let first = fromEnd ? items.last : items.first {
                // Even one element is too big: keep it, shortened.
                kept = [fit(first, size: estimate(first), budget: max(budget - 2, 0), key: key, tailKeys: tailKeys, counters: &counters)]
                counters.items += items.count - 1
            } else {
                counters.items += items.count - kept.count
            }
            return .array(kept)
        case .object(let fields):
            var keys = fields.keys.sorted()
            let maxKeys = max(1, budget / minimumPerKey)
            if keys.count > maxKeys {
                counters.items += keys.count - maxKeys
                keys = Array(keys.prefix(maxKeys))
            }
            // Sizes once per round; smallest first, so what is small stays whole and the rest share the remainder.
            let entries = keys.map { (key: $0, size: keyCost($0), value: fields[$0] ?? .null) }
                .map { (key: $0.key, cost: $0.size, value: $0.value, size: estimate($0.value)) }
                .sorted { ($0.cost + $0.size, $0.key) < ($1.cost + $1.size, $1.key) }
            var remaining = max(budget - 2, 0)
            var left = entries.count
            var out: [String: JSONValue] = [:]
            for entry in entries {
                let share = remaining / max(left, 1)
                let kept: JSONValue
                if entry.cost + entry.size <= share {
                    kept = entry.value
                } else {
                    kept = fit(entry.value, size: entry.size, budget: max(share - entry.cost, 0), key: entry.key, tailKeys: tailKeys, counters: &counters)
                }
                out[entry.key] = kept
                // A kept-whole value costs what we measured; a cut one is at most its share.
                remaining = max(remaining - entry.cost - (entry.cost + entry.size <= share ? entry.size : max(share - entry.cost, 0)), 0)
                left -= 1
            }
            return .object(out)
        default:
            return value
        }
    }

    // MARK: Size

    private static func keyCost(_ key: String) -> Int { estimate(.string(key)) + 2 }

    /// A fast upper-ish estimate of the encoded size (no allocation of the encoded text).
    static func estimate(_ value: JSONValue) -> Int {
        switch value {
        case .null: return 4
        case .bool: return 5
        case .int(let i): return String(i).utf8.count
        case .double: return 24
        case .string(let s):
            // Short strings are scanned for escapes; long ones are estimated with a margin (the retry loop in `limit` covers
            // the rare string that is mostly escapes), which keeps this O(1) per large value.
            let count = s.utf8.count
            if count > 256 { return count + count / 32 + 2 }
            var n = 2 + count
            for byte in s.utf8 where byte < 0x20 || byte == 0x22 || byte == 0x5C { n += byte < 0x20 ? 5 : 1 }
            return n
        case .array(let a):
            return 2 + a.reduce(0) { $0 + estimate($1) + 1 }
        case .object(let o):
            return 2 + o.reduce(0) { $0 + keyCost($1.key) + estimate($1.value) }
        }
    }

    static func encodedSize(_ v: JSONValue) -> Int { v.jsonString().utf8.count }
}
