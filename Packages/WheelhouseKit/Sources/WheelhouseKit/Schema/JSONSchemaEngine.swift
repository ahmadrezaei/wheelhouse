import Foundation

/// One step of a path into a document: a mapping key or any sequence item (the schema is the same for every item).
public enum SchemaPathSegment: Hashable, Sendable {
    case key(String)
    case item
}

/// A schema document with the root that `$ref`s point into (`#/components/schemas/…`, `#/definitions/…`, `#/$defs/…`).
public struct SchemaDocument: Sendable {
    public var root: JSONValue
    public init(root: JSONValue) { self.root = root }

    /// Follows `$ref` chains. Returns the target and the last reference name (used for the quantity check).
    func resolve(_ schema: JSONValue) -> (schema: JSONValue, refName: String?) {
        var current = schema
        var name: String?
        var hops = 0
        while let ref = current["$ref"]?.stringValue, hops < 16 {
            hops += 1
            guard ref.hasPrefix("#/"), let target = pointer(String(ref.dropFirst(2))) else { break }
            name = ref.split(separator: "/").last.map(String.init)
            current = target
        }
        return (current, name)
    }

    func pointer(_ path: String) -> JSONValue? {
        var current = root
        for raw in path.split(separator: "/") {
            let part = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            guard let next = current[part] else { return nil }
            current = next
        }
        return current
    }
}

/// How the engine reads a schema.
public struct SchemaOptions: Sendable {
    /// Kubernetes OpenAPI never says `additionalProperties: false`, but the API server rejects unknown fields: an object with
    /// `properties` and no `additionalProperties` is closed. Plain JSON Schema (`values.schema.json`) leaves objects open.
    public var closedObjects: Bool
    public init(closedObjects: Bool) { self.closedObjects = closedObjects }
    public static let kubernetes = SchemaOptions(closedObjects: true)
    public static let jsonSchema = SchemaOptions(closedObjects: false)
}

/// A finding of the schema check, positioned in the text.
public struct SchemaIssue: Hashable, Sendable {
    public enum Severity: Sendable { case error, warning }
    public var span: YAMLSpan
    public var message: String
    public var severity: Severity
    /// The dotted path of the field, for the Issues list.
    public var path: String
}

/// The property list and requirements of a schema with `allOf` members merged in.
struct FlatObjectSchema {
    var properties: [String: JSONValue] = [:]
    var required: Set<String> = []
    var additional: JSONValue?
    var preserveUnknown = false
    var hasObjectShape = false
    var hasPatternProperties = false
}

/// JSON Schema (draft 07 and 2020-12 subset) and Kubernetes OpenAPI v3 checks over ``YAMLNode`` trees.
public struct JSONSchemaEngine: Sendable {
    public var document: SchemaDocument
    public var options: SchemaOptions
    static let maxDepth = 48

    public init(document: SchemaDocument, options: SchemaOptions) {
        self.document = document
        self.options = options
    }

    // MARK: Validation

    public func validate(_ node: YAMLNode, schema: JSONValue) -> [SchemaIssue] {
        var out: [SchemaIssue] = []
        check(node, schema, anchor: node.span, path: "", depth: 0, into: &out)
        return out
    }

    private func check(_ node: YAMLNode, _ raw: JSONValue, anchor: YAMLSpan, path: String, depth: Int, membersOnly: Bool = false, into out: inout [SchemaIssue]) {
        guard depth < Self.maxDepth else { return }
        let (schema, refName) = document.resolve(raw)
        guard schema.objectValue != nil else { return }

        // null means "unset" to the API server and to Helm. Checked first so a oneOf of string and number does not count it twice.
        if node.kind == .scalar, node.scalar.isNull, !node.isQuoted { return }

        // A mapping reads the properties, required and additionalProperties of its `allOf` members through `flatten`, so walking the
        // members fully would report every finding below it twice. It still walks them for their type, oneOf and anyOf (a mapping
        // where an IntOrString or a timestamp is expected).
        if let all = schema["allOf"]?.arrayValue {
            for sub in all { check(node, sub, anchor: anchor, path: path, depth: depth + 1, membersOnly: membersOnly || node.kind == .mapping, into: &out) }
        }
        if let any = schema["anyOf"]?.arrayValue, !any.isEmpty {
            if !any.contains(where: { matches(node, $0, depth: depth + 1) }) {
                out.append(SchemaIssue(span: node.span.line == anchor.line ? node.span : anchor, message: "Doesn’t match any of the allowed shapes", severity: .error, path: path))
            }
        }
        if let one = schema["oneOf"]?.arrayValue, !one.isEmpty {
            let count = one.filter { matches(node, $0, depth: depth + 1) }.count
            if count == 0 {
                out.append(SchemaIssue(span: node.span.line == anchor.line ? node.span : anchor, message: "Doesn’t match any of the allowed shapes", severity: .error, path: path))
            } else if count > 1, schema["x-kubernetes-int-or-string"] == nil {
                out.append(SchemaIssue(span: anchor, message: "Matches more than one of the allowed shapes", severity: .error, path: path))
            }
        }

        if schema["x-kubernetes-int-or-string"]?.boolValue == true {
            if !(node.kind == .scalar && (node.scalar.intValue != nil || node.scalar.stringValue != nil)) {
                out.append(SchemaIssue(span: node.span, message: "Expected an integer or a string", severity: .error, path: path))
            }
            return
        }

        let types = declaredTypes(schema)
        if !types.isEmpty, !types.contains(where: { typeMatches(node, $0) }) {
            out.append(SchemaIssue(span: node.span, message: "Expected \(describe(types)), found \(found(node))", severity: .error, path: path))
            return
        }

        if let values = schema["enum"]?.arrayValue, node.kind == .scalar, !values.contains(where: { enumMatches($0, node) }) {
            let shown = values.prefix(8).map { $0.displayString }.joined(separator: ", ")
            out.append(SchemaIssue(span: node.span, message: "Must be one of: \(shown)\(values.count > 8 ? ", …" : "")", severity: .error, path: path))
        }
        if let const = schema["const"], node.kind == .scalar, !enumMatches(const, node) {
            out.append(SchemaIssue(span: node.span, message: "Must be \(const.displayString)", severity: .error, path: path))
        }

        if membersOnly { return }
        switch node.kind {
        case .scalar: checkScalar(node, schema, refName: refName, path: path, into: &out)
        case .mapping: checkMapping(node, schema, anchor: anchor, path: path, depth: depth, into: &out)
        case .sequence: checkSequence(node, schema, path: path, depth: depth, into: &out)
        }
    }

    private func matches(_ node: YAMLNode, _ schema: JSONValue, depth: Int) -> Bool {
        var local: [SchemaIssue] = []
        check(node, schema, anchor: node.span, path: "", depth: depth, into: &local)
        return !local.contains { $0.severity == .error }
    }

    private func checkScalar(_ node: YAMLNode, _ schema: JSONValue, refName: String?, path: String, into out: inout [SchemaIssue]) {
        if let s = node.scalar.stringValue {
            if let min = schema["minLength"]?.intValue, s.count < min {
                out.append(SchemaIssue(span: node.span, message: "Must be at least \(min) characters", severity: .error, path: path))
            }
            if let max = schema["maxLength"]?.intValue, s.count > max {
                out.append(SchemaIssue(span: node.span, message: "Must be at most \(max) characters", severity: .error, path: path))
            }
            if let pattern = schema["pattern"]?.stringValue, let re = Self.regex(pattern),
               re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) == nil {
                out.append(SchemaIssue(span: node.span, message: "Doesn’t match the pattern \(pattern)", severity: .error, path: path))
            }
            if refName?.hasSuffix(".Quantity") == true, !SchemaFormats.isQuantity(s) {
                out.append(SchemaIssue(span: node.span, message: "Not a valid quantity (for example 500m, 1Gi, 2)", severity: .error, path: path))
            }
        }
        if let n = node.scalar.doubleValue, node.scalar.stringValue == nil {
            if let min = schema["minimum"]?.doubleValue, n < min {
                out.append(SchemaIssue(span: node.span, message: "Must be at least \(JSONValue.double(min).displayString)", severity: .error, path: path))
            }
            if let max = schema["maximum"]?.doubleValue, n > max {
                out.append(SchemaIssue(span: node.span, message: "Must be at most \(JSONValue.double(max).displayString)", severity: .error, path: path))
            }
        }
    }

    private func checkSequence(_ node: YAMLNode, _ schema: JSONValue, path: String, depth: Int, into out: inout [SchemaIssue]) {
        if let min = schema["minItems"]?.intValue, node.items.count < min {
            out.append(SchemaIssue(span: node.span, message: "Needs at least \(min) item\(min == 1 ? "" : "s")", severity: .error, path: path))
        }
        if let max = schema["maxItems"]?.intValue, node.items.count > max {
            out.append(SchemaIssue(span: node.span, message: "Allows at most \(max) item\(max == 1 ? "" : "s")", severity: .error, path: path))
        }
        guard let items = schema["items"], items.objectValue != nil else { return }
        for (i, item) in node.items.enumerated() {
            check(item, items, anchor: item.span, path: "\(path)[\(i)]", depth: depth + 1, into: &out)
        }
    }

    private func checkMapping(_ node: YAMLNode, _ schema: JSONValue, anchor: YAMLSpan, path: String, depth: Int, into out: inout [SchemaIssue]) {
        let flat = flatten(schema, depth: 0)
        guard flat.hasObjectShape || schema["additionalProperties"] != nil || !flat.required.isEmpty else { return }
        let keys = Set(node.entries.map(\.key))
        for name in flat.required.sorted() where !keys.contains(name) {
            out.append(SchemaIssue(span: anchor, message: "Missing required field “\(name)”", severity: .error, path: path))
        }
        let closed = options.closedObjects && !flat.properties.isEmpty && flat.additional == nil && !flat.preserveUnknown && !flat.hasPatternProperties
        for entry in node.entries {
            let childPath = path.isEmpty ? entry.key : "\(path).\(entry.key)"
            if let prop = flat.properties[entry.key] {
                check(entry.value, prop, anchor: entry.keySpan, path: childPath, depth: depth + 1, into: &out)
            } else if let extra = flat.additional {
                if extra.objectValue != nil {
                    check(entry.value, extra, anchor: entry.keySpan, path: childPath, depth: depth + 1, into: &out)
                } else if extra.boolValue == false, !flat.hasPatternProperties {
                    out.append(unknown(entry, in: flat, path: childPath, severity: .error))
                }
            } else if closed {
                out.append(unknown(entry, in: flat, path: childPath))
            }
        }
    }

    private func unknown(_ entry: YAMLEntry, in flat: FlatObjectSchema, path: String, severity: SchemaIssue.Severity = .warning) -> SchemaIssue {
        var message = "Unknown field “\(entry.key)”"
        let typed = entry.key.lowercased()
        var best: (name: String, score: Int)?
        for name in flat.properties.keys.sorted() {
            let score = Self.distance(name.lowercased(), typed)
            if score <= 2, score < entry.key.count, score < (best?.score ?? Int.max) { best = (name, score) }
        }
        if let best { message += ". Did you mean “\(best.name)”?" }
        return SchemaIssue(span: entry.keySpan, message: message, severity: severity, path: path)
    }

    // MARK: Shape helpers

    func flatten(_ raw: JSONValue, depth: Int) -> FlatObjectSchema {
        var out = FlatObjectSchema()
        guard depth < 12 else { return out }
        let schema = document.resolve(raw).schema
        if let props = schema["properties"]?.objectValue {
            out.hasObjectShape = true
            out.properties = props
        }
        if let req = schema["required"]?.arrayValue { out.required = Set(req.compactMap(\.stringValue)) }
        out.additional = schema["additionalProperties"]
        out.hasPatternProperties = schema["patternProperties"] != nil
        out.preserveUnknown = schema["x-kubernetes-preserve-unknown-fields"]?.boolValue == true
            || schema["x-kubernetes-embedded-resource"]?.boolValue == true
        if declaredTypes(schema).contains("object") { out.hasObjectShape = true }
        for sub in schema["allOf"]?.arrayValue ?? [] {
            let inner = flatten(sub, depth: depth + 1)
            out.properties.merge(inner.properties) { a, _ in a }
            out.required.formUnion(inner.required)
            out.additional = out.additional ?? inner.additional
            out.preserveUnknown = out.preserveUnknown || inner.preserveUnknown
            out.hasObjectShape = out.hasObjectShape || inner.hasObjectShape
            out.hasPatternProperties = out.hasPatternProperties || inner.hasPatternProperties
        }
        return out
    }

    func declaredTypes(_ schema: JSONValue) -> [String] {
        if let t = schema["type"]?.stringValue { return [t] }
        if let t = schema["type"]?.arrayValue { return t.compactMap(\.stringValue) }
        return []
    }

    private func typeMatches(_ node: YAMLNode, _ type: String) -> Bool {
        switch type {
        case "object": return node.kind == .mapping
        case "array": return node.kind == .sequence
        case "null": return node.kind == .scalar && node.scalar.isNull
        case "string": return node.kind == .scalar && node.scalar.stringValue != nil
        case "boolean": return node.kind == .scalar && node.scalar.boolValue != nil
        case "integer":
            guard node.kind == .scalar else { return false }
            if case .int = node.scalar { return true }
            if case .double(let d) = node.scalar { return d == d.rounded() }
            return false
        case "number":
            guard node.kind == .scalar else { return false }
            switch node.scalar { case .int, .double: return true; default: return false }
        default: return true
        }
    }

    private func found(_ node: YAMLNode) -> String {
        switch node.kind {
        case .mapping: return "a mapping"
        case .sequence: return "a list"
        case .scalar:
            switch node.scalar {
            case .bool: return "a boolean"
            case .int, .double: return "a number"
            case .null: return "null"
            default: return "a string"
            }
        }
    }

    private func describe(_ types: [String]) -> String {
        types.map { t in
            switch t {
            case "object": "a mapping"
            case "array": "a list"
            case "boolean": "a boolean"
            case "integer": "an integer"
            case "number": "a number"
            case "string": "a string"
            default: t
            }
        }.joined(separator: " or ")
    }

    private func enumMatches(_ allowed: JSONValue, _ node: YAMLNode) -> Bool {
        if allowed == node.scalar { return true }
        // `replicas: 3` against an enum of strings is a mismatch; `1.0` against 1 is not.
        if let a = allowed.doubleValue, let b = node.scalar.doubleValue, allowed.stringValue == nil, node.scalar.stringValue == nil { return a == b }
        return false
    }

    // MARK: Navigation (completion and hover)

    /// The schema of the value at `path`, with `allOf` merged for property lookup.
    public func schema(at path: [SchemaPathSegment], from root: JSONValue) -> JSONValue? {
        var current = root
        for seg in path {
            let resolved = document.resolve(current).schema
            switch seg {
            case .key(let key):
                let flat = flatten(resolved, depth: 0)
                if let p = flat.properties[key] { current = p }
                else if let extra = flat.additional, extra.objectValue != nil { current = extra }
                else { return nil }
            case .item:
                guard let items = firstItems(resolved, depth: 0) else { return nil }
                current = items
            }
        }
        return current
    }

    private func firstItems(_ schema: JSONValue, depth: Int) -> JSONValue? {
        guard depth < 8 else { return nil }
        if let items = schema["items"], items.objectValue != nil { return items }
        for sub in schema["allOf"]?.arrayValue ?? [] {
            if let found = firstItems(document.resolve(sub).schema, depth: depth + 1) { return found }
        }
        return nil
    }

    /// The `description`, looking through references and `allOf` wrappers.
    public func description(of raw: JSONValue) -> String? {
        if let d = raw["description"]?.stringValue, !d.isEmpty { return d }
        let schema = document.resolve(raw).schema
        if let d = schema["description"]?.stringValue, !d.isEmpty { return d }
        for sub in schema["allOf"]?.arrayValue ?? [] {
            if let d = description(of: sub) { return d }
        }
        return nil
    }

    /// A short type label such as `string`, `integer`, `[]Container` or `map[string]string`.
    public func typeLabel(of raw: JSONValue, depth: Int = 0) -> String {
        let (schema, name) = document.resolve(raw)
        if schema["x-kubernetes-int-or-string"]?.boolValue == true { return "int or string" }
        let types = declaredTypes(schema)
        if types.contains("array"), let items = firstItems(schema, depth: 0), depth < 3 { return "[]" + typeLabel(of: items, depth: depth + 1) }
        if types.contains("object"), schema["properties"] == nil, let extra = schema["additionalProperties"], extra.objectValue != nil, depth < 3 {
            return "map[string]" + typeLabel(of: extra, depth: depth + 1)
        }
        if let name, schema["properties"] != nil || schema["allOf"] != nil { return name.split(separator: ".").last.map(String.init) ?? name }
        if name?.hasSuffix(".Quantity") == true { return "quantity" }
        if !types.isEmpty { return types.filter { $0 != "null" }.joined(separator: " | ") }
        if schema["oneOf"] != nil || schema["anyOf"] != nil { return "choice" }
        if let sub = schema["allOf"]?.arrayValue?.first, depth < 3 { return typeLabel(of: sub, depth: depth + 1) }
        return "any"
    }

    /// Possible values of a scalar field: `enum`, booleans and the `const`.
    public func valueChoices(of raw: JSONValue) -> [String] {
        let schema = document.resolve(raw).schema
        if let values = schema["enum"]?.arrayValue { return values.map(\.displayString) }
        if let c = schema["const"] { return [c.displayString] }
        if declaredTypes(schema).contains("boolean") { return ["true", "false"] }
        for sub in schema["allOf"]?.arrayValue ?? [] {
            let inner = valueChoices(of: sub)
            if !inner.isEmpty { return inner }
        }
        return []
    }

    /// The properties of the object schema at `raw`, sorted required-first then alphabetically.
    public func propertyList(of raw: JSONValue) -> [SchemaProperty] {
        let flat = flatten(raw, depth: 0)
        return flat.properties.map { name, schema in
            SchemaProperty(name: name, type: typeLabel(of: schema), description: description(of: schema), required: flat.required.contains(name), schema: schema)
        }
        .sorted { a, b in a.required != b.required ? a.required : a.name < b.name }
    }

    // MARK: Utilities

    private static let regexCache = RegexCache()
    static func regex(_ pattern: String) -> NSRegularExpression? { regexCache.regex(pattern) }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var row = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                row[j] = min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = row
        }
        return prev[b.count]
    }
}

/// A field of an object schema.
public struct SchemaProperty: Sendable {
    public var name: String
    public var type: String
    public var description: String?
    public var required: Bool
    public var schema: JSONValue
}

private final class RegexCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: NSRegularExpression?] = [:]
    func regex(_ pattern: String) -> NSRegularExpression? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[pattern] { return hit }
        let re = try? NSRegularExpression(pattern: pattern)
        cache[pattern] = re
        return re
    }
}

extension JSONValue {
    var displayString: String {
        switch self {
        case .string(let s): s
        case .int(let i): String(i)
        case .double(let d): d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
        case .bool(let b): b ? "true" : "false"
        case .null: "null"
        default: jsonString(pretty: false)
        }
    }
}

/// Format checks that need more than a regular expression.
public enum SchemaFormats {
    /// `resource.Quantity`: a decimal number with an optional SI or binary suffix, or a decimal exponent.
    public static func isQuantity(_ s: String) -> Bool {
        guard !s.isEmpty, let re = JSONSchemaEngine.regex(quantityPattern) else { return false }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
    private static let quantityPattern = "^[+-]?(\\d+(\\.\\d*)?|\\.\\d+)(([eE][+-]?\\d+)|Ki|Mi|Gi|Ti|Pi|Ei|[numkMGTPE])?$"
}
