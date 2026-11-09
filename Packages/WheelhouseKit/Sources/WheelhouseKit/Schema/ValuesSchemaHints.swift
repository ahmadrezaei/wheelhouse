import Foundation

/// Schema hints for a Helm values file, usable on their own (Chart Room's values editor, M6b, builds one per chart version).
///
/// With a `values.schema.json` the hints are exact: type errors, enum values, `required`, descriptions. Without one the hints are
/// inferred from the chart's default values: each key takes the type of its default, and the comment above a key (helm-docs
/// `# -- text` or a plain `# text`) becomes its description. Inferred findings are warnings, never errors, because a default of
/// `null` or `1` says little about what is allowed.
public struct ValuesSchemaHints: Sendable {
    public enum Origin: Sendable, Equatable {
        /// A real `values.schema.json`.
        case schema
        /// Inferred from the chart's default values.
        case inferred
        /// Neither: no hints.
        case none
    }

    public let origin: Origin
    private let target: ManifestAssist.Target?

    /// `schema` is the parsed `values.schema.json` (nil when the chart has none); `defaults` is the chart's `values.yaml` text.
    public init(schema: JSONValue?, defaults: String?) {
        if let schema, schema.objectValue != nil, !(schema.objectValue?.isEmpty ?? true) {
            origin = .schema
            target = ManifestAssist.Target(engine: JSONSchemaEngine(document: SchemaDocument(root: schema), options: .jsonSchema), root: schema)
        } else if let defaults, let value = try? YAMLCodec.parse(defaults), value.objectValue != nil {
            let inferred = Self.infer(value, comments: Self.comments(in: defaults), path: [])
            origin = .inferred
            target = ManifestAssist.Target(engine: JSONSchemaEngine(document: SchemaDocument(root: inferred), options: .jsonSchema), root: inferred)
        } else {
            origin = .none
            target = nil
        }
    }

    /// From the bytes of `values.schema.json` (invalid JSON counts as no schema).
    public init(schemaData: Data?, defaults: String?) {
        self.init(schema: schemaData.flatMap { try? JSONValue.fastParse($0) }, defaults: defaults)
    }

    /// Findings for a values document. Positions are in `text`.
    public func diagnostics(for text: String) -> [ManifestDiagnostic] {
        var out: [ManifestDiagnostic] = []
        for doc in YAMLNodeMap.documents(in: text) {
            if let d = doc.diagnostic {
                out.append(ManifestDiagnostic(span: YAMLSpan(line: d.line, column: max(0, d.column - 1), endLine: d.line, endColumn: max(0, d.column - 1) + 1),
                                              message: d.message, severity: .error, source: .syntax, path: ""))
            } else if let root = doc.root, let target {
                for issue in target.engine.validate(root, schema: target.root) {
                    out.append(ManifestDiagnostic(span: issue.span, message: issue.message,
                                                  severity: origin == .inferred || issue.severity == .warning ? .warning : .error, source: .schema, path: issue.path))
                }
            }
        }
        return out.sorted { ($0.span.line, $0.span.column) < ($1.span.line, $1.span.column) }
    }

    public func completions(text: String, offset: Int) -> ManifestCompletionResult {
        let cursor = YAMLCursor.make(text: text, offset: offset)
        return ManifestAssist.complete(cursor: cursor, target: target, known: [], manifestFallback: false)
    }

    public func hover(text: String, offset: Int) -> ManifestHover? {
        target.flatMap { ManifestAssist.hover(text: text, offset: offset, target: $0) }
    }

    // MARK: Inference

    /// The JSON Schema a values file implies: types from defaults, descriptions from comments.
    static func infer(_ value: JSONValue, comments: [[SchemaPathSegment]: String], path: [SchemaPathSegment]) -> JSONValue {
        var schema: [String: JSONValue]
        switch value {
        case .object(let o):
            schema = ["type": "object", "properties": .object(Dictionary(uniqueKeysWithValues: o.map { key, v in
                (key, infer(v, comments: comments, path: path + [.key(key)]))
            }))]
        case .array(let a):
            schema = ["type": "array"]
            if let first = a.first { schema["items"] = infer(first, comments: comments, path: path + [.item]) }
        case .string: schema = ["type": "string"]
        case .bool: schema = ["type": "boolean"]
        case .int: schema = ["type": "integer"]
        case .double: schema = ["type": "number"]
        case .null: schema = [:]
        }
        if let text = comments[path] { schema["description"] = .string(text) }
        return .object(schema)
    }

    /// Comment blocks directly above keys, by key path.
    static func comments(in text: String) -> [[SchemaPathSegment]: String] {
        var out: [[SchemaPathSegment]: String] = [:]
        var pending: [String] = []
        var path = YAMLIndentPath()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let shape = YAMLLineShape(raw)
            let trimmed = raw.drop { $0 == " " }
            if trimmed.hasPrefix("#") {
                var body = trimmed.drop { $0 == "#" }
                if body.hasPrefix(" --") { body = body.dropFirst(3) }
                pending.append(body.trimmingCharacters(in: .whitespaces))
                continue
            }
            if shape.isBlankOrComment { if trimmed.isEmpty { pending.removeAll() }; continue }
            path.advance(shape)
            if shape.key != nil, !pending.isEmpty {
                let joined = pending.filter { !$0.isEmpty && !$0.hasPrefix("@") }.joined(separator: " ")
                if !joined.isEmpty { out[path.path] = joined }
            }
            pending.removeAll()
        }
        return out
    }
}
