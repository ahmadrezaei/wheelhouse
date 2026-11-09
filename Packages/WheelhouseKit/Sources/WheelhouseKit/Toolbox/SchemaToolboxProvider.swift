import Foundation

/// The `explain_field` tool (M7): what a field of a resource schema is, from the cluster's OpenAPI document or the bundled schema.
///
/// One conforming type per family (ARCHITECTURE-MAC section 15.3); the app passes it to ``ClusterToolbox``'s `extensions`. It gets
/// its schemas from a per-cluster lookup injected at construction, so it never touches a client.
public struct SchemaToolboxProvider: ToolboxExtensionProviding {
    public typealias Lookup = @Sendable (ClusterConfig) async -> (any ManifestSchemaProviding)?
    private let lookup: Lookup

    public init(schemas lookup: @escaping Lookup) { self.lookup = lookup }

    public var tools: Set<ReadTool> { [.explainField] }

    public func call(_ tool: ReadTool, cluster: ClusterConfig, access: ReadOnlyKubeAccess, input: JSONValue, redactor: Redactor) async throws -> JSONValue {
        guard tool == .explainField else { throw KubeError.unsupported("Unknown schema tool.") }
        guard let name = input["kind"]?.stringValue, !name.isEmpty else { throw KubeError.invalid(message: "kind is required.", causes: []) }
        let discovery = try? await access.discovery()
        guard let kind = KindResolver.resolve(name, discovery: discovery) else {
            return ["error": "unknown_kind", "message": .string("The cluster has no kind “\(name)”.")]
        }
        guard let provider = await lookup(cluster),
              let found = await provider.kindSchema(for: GroupVersionKind(group: kind.group, version: kind.version, kind: kind.kind)) else {
            return ["error": "schema_unavailable", "message": .string("No schema is available for \(kind.kind).")]
        }
        let path = (input["path"]?.stringValue ?? "").split(separator: ".").map(String.init).filter { !$0.isEmpty }
        let engine = found.engine
        guard let (field, resolved) = Self.walk(path, from: found.schema, engine: engine) else {
            return ["error": "unknown_field", "message": .string("\(kind.kind) has no field “\(path.joined(separator: "."))”.")]
        }
        var out: JSONValue = [
            "kind": .string(kind.kind), "apiVersion": .string(kind.apiVersion), "path": .string(resolved.joined(separator: ".")),
            "type": .string(engine.typeLabel(of: field)),
        ]
        if let text = engine.description(of: field) { out["description"] = .string(Self.cut(text, 600)) }
        let choices = engine.valueChoices(of: field)
        if !choices.isEmpty, choices != ["true", "false"] { out["enum"] = .array(choices.map { .string($0) }) }
        // Fields of the object, or of the items when the field is a list.
        let inner = engine.schema(at: [.item], from: field) ?? field
        let props = engine.propertyList(of: inner)
        if !props.isEmpty {
            out["fields"] = .array(props.prefix(80).map { p in
                var f: JSONValue = ["name": .string(p.name), "type": .string(p.type)]
                if p.required { f["required"] = true }
                if let d = p.description { f["description"] = .string(Self.cut(d, 200)) }
                return f
            })
        }
        if let source = found.source.note(serverVersion: nil) { out["note"] = .string(source) }
        return out
    }

    /// Follows `a.b.c`; a list in the middle is entered automatically (`containers.image`), and `[]` or `[0]` are ignored.
    static func walk(_ path: [String], from root: JSONValue, engine: JSONSchemaEngine) -> (JSONValue, [String])? {
        var current = root
        var resolved: [String] = []
        for raw in path {
            let key = raw.split(separator: "[").first.map(String.init) ?? raw
            if key.isEmpty { continue }
            if let items = engine.schema(at: [.item], from: current), engine.schema(at: [.key(key)], from: current) == nil {
                current = items
                resolved.append("[]")
            }
            guard let next = engine.schema(at: [.key(key)], from: current) else { return nil }
            current = next
            resolved.append(key)
        }
        return (current, resolved.filter { $0 != "[]" })
    }

    private static func cut(_ s: String, _ limit: Int) -> String { s.count <= limit ? s : String(s.prefix(limit - 1)) + "…" }
}
