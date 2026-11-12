import Foundation

/// Checks a tool call's input against the tool's JSON schema with the Kit schema engine (ARCHITECTURE-MAC section 9.2).
///
/// Eager input streaming means the server no longer validates, so every input is checked here before a tool runs. A failure becomes
/// a `tool_result` with `is_error: true` and this message. The engine skips an unquoted null (null means "unset" to Kubernetes), but a
/// model that sends `{"cluster": null}` has not given the field, so nulls are refused first.
public enum ToolInputValidator {
    /// The first problems, or nil when the input is valid. The schema is the catalog's own, with its bounds.
    public static func problem(for input: JSONValue, schema: JSONValue) -> String? {
        guard input.objectValue != nil else { return "The input must be a JSON object." }
        if let path = nullPath(in: input, path: "") { return "\(path.isEmpty ? "input" : path) is null; leave out a field you do not need." }
        let text = input.jsonString()
        guard let root = YAMLNodeMap.documents(in: text).first?.root else { return "The input could not be read." }
        let engine = JSONSchemaEngine(document: SchemaDocument(root: schema), options: .jsonSchema)
        let errors = engine.validate(root, schema: schema).filter { $0.severity == .error }
        guard !errors.isEmpty else { return nil }
        return errors.prefix(3).map { $0.path.isEmpty ? $0.message : "\($0.path): \($0.message)" }.joined(separator: "; ")
    }

    private static func nullPath(in value: JSONValue, path: String) -> String? {
        switch value {
        case .null: return path
        case .object(let fields):
            for key in fields.keys.sorted() { if let found = nullPath(in: fields[key] ?? .null, path: path.isEmpty ? key : "\(path).\(key)") { return found } }
            return nil
        case .array(let items):
            for (index, item) in items.enumerated() { if let found = nullPath(in: item, path: "\(path)[\(index)]") { return found } }
            return nil
        default: return nil
        }
    }
}

/// Lets the view take streamed text at most four times a second (DESIGN-MAC performance budget, ARCHITECTURE-MAC section 15.1).
public struct UpdateGate: Sendable {
    public static let minimumInterval: TimeInterval = 0.25
    private var last: Date?

    public init() {}

    /// True when enough time has passed since the last published update; the caller publishes and the gate remembers the time.
    public mutating func shouldPublish(at now: Date) -> Bool {
        if let last, now.timeIntervalSince(last) < Self.minimumInterval { return false }
        last = now
        return true
    }

    public mutating func reset() { last = nil }
}
