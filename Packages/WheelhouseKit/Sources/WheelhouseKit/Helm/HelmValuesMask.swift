import Foundation

/// Release values are treated like Secret data (ARCHITECTURE-MAC §5.1): values under keys that look sensitive are masked until
/// the user reveals them (Touch ID in the app), and First Mate and Beacon only ever see the masked form.
public enum HelmValuesMask {
    public static let placeholder = "••••••••"
    static let needles = ["password", "passwd", "secret", "token", "key", "credential", "dsn", "apikey"]

    public static func isSensitiveKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return needles.contains { lower.contains($0) }
    }

    /// Replaces every non-empty string or number under a sensitive key (at any depth below it) with the placeholder.
    public static func masked(_ value: JSONValue) -> JSONValue { mask(value, inherited: false) }

    private static func mask(_ value: JSONValue, inherited: Bool) -> JSONValue {
        switch value {
        case .object(let object):
            var out: [String: JSONValue] = [:]
            let sensitiveName = hasSensitiveName(object)
            for (key, child) in object { out[key] = mask(child, inherited: inherited || isSensitiveKey(key) || (sensitiveName && key == "value")) }
            return .object(out)
        case .array(let items):
            return .array(items.map { mask($0, inherited: inherited) })
        case .string(let s):
            return inherited && !s.isEmpty ? .string(placeholder) : value
        case .int, .double:
            return inherited ? .string(placeholder) : value
        default:
            return value
        }
    }

    /// An env-style entry (`{name: DB_PASSWORD, value: …}`): the value is sensitive when its sibling name is.
    static func hasSensitiveName(_ object: [String: JSONValue]) -> Bool {
        guard let name = object["name"]?.stringValue else { return false }
        return isSensitiveKey(name)
    }

    /// True when masking changes anything (decides whether the "Reveal" control is shown).
    public static func containsSensitiveValues(_ value: JSONValue) -> Bool { masked(value) != value }

    /// YAML for display; masked unless `revealed`.
    public static func yaml(_ value: JSONValue, revealed: Bool) -> String {
        guard case .object(let o) = value, !o.isEmpty else { return "# no values\n" }
        return YAMLCodec.dump(revealed ? value : masked(value))
    }
}
