import Foundation

/// Evaluates the simple JSONPath subset used by CRD `additionalPrinterColumns` (`.spec.replicas`, `.status.conditions[0].type`, `{.metadata.name}`).
public enum JSONPathLite {
    public static func evaluate(_ path: String, in value: JSONValue) -> JSONValue? {
        var p = path.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("{"), p.hasSuffix("}") { p = String(p.dropFirst().dropLast()) }
        if p.hasPrefix("$") { p.removeFirst() }
        var current: JSONValue? = value
        var token = ""
        func flush() { if !token.isEmpty { current = current?[token]; token = "" } }
        var i = p.startIndex
        while i < p.endIndex, current != nil {
            let ch = p[i]
            if ch == "." { flush() }
            else if ch == "[" {
                flush()
                guard let close = p[i...].firstIndex(of: "]") else { return nil }
                let inner = p[p.index(after: i)..<close].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                if let idx = Int(inner) { current = current?[idx] } else { current = current?[inner] }
                i = close
            } else { token.append(ch) }
            i = p.index(after: i)
        }
        flush()
        return current
    }

    /// Display text for a printer-column value.
    public static func display(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let s): s
        case .int(let i): String(i)
        case .double(let d): d.formatted(.number.precision(.fractionLength(0...2)))
        case .bool(let b): b ? "true" : "false"
        case .array(let a): a.compactMap { display($0) }.joined(separator: ",")
        case .object(let o): "{\(o.count)}"
        default: nil
        }
    }
}
