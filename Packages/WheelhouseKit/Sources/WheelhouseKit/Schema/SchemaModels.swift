import Foundation

/// A Kubernetes kind: group, version and kind name.
public struct GroupVersionKind: Hashable, Sendable {
    public var group: String
    public var version: String
    public var kind: String

    public init(group: String, version: String, kind: String) {
        self.group = group
        self.version = version
        self.kind = kind
    }

    /// From an `apiVersion` such as `apps/v1` or `v1`.
    public init(apiVersion: String, kind: String) {
        let parts = apiVersion.split(separator: "/", maxSplits: 1).map(String.init)
        self.init(group: parts.count == 2 ? parts[0] : "", version: parts.last ?? apiVersion, kind: kind)
    }

    public var apiVersion: String { group.isEmpty ? version : "\(group)/\(version)" }

    /// The path of the group-version in `/openapi/v3`'s index: `api/v1` or `apis/<group>/<version>`.
    public var groupVersionPath: String { group.isEmpty ? "api/\(version)" : "apis/\(group)/\(version)" }
}

/// Where a schema came from.
public enum SchemaSource: Sendable, Equatable {
    /// The cluster's own OpenAPI document (CRDs included).
    case cluster
    /// The schema bundled with the app, for the given Kubernetes minor version (for example "1.32").
    case bundled(minor: String)

    /// The note the editor shows above the text, nil for the cluster's own schema.
    public var note: String? {
        switch self {
        case .cluster: nil
        case .bundled(let minor): "Schema from Kubernetes \(minor), cluster schema unavailable"
        }
    }
}

/// The schema of one kind with the document its `$ref`s point into.
public struct KindSchema: Sendable {
    public var document: SchemaDocument
    public var schema: JSONValue
    public var source: SchemaSource

    public init(document: SchemaDocument, schema: JSONValue, source: SchemaSource) {
        self.document = document
        self.schema = schema
        self.source = source
    }

    public var engine: JSONSchemaEngine { JSONSchemaEngine(document: document, options: .kubernetes) }
}

/// Anything that can look up the schema of a kind: the OpenAPI store, or a fixed set in tests.
public protocol ManifestSchemaProviding: Sendable {
    func kindSchema(for gvk: GroupVersionKind) async -> KindSchema?
}

/// A schema group-version document, trimmed to its `components.schemas`, with an index from kind to schema name.
struct LoadedSchemaDocument: Sendable {
    var document: SchemaDocument
    var kinds: [GroupVersionKind: String]
    var cost: Int

    init(components root: JSONValue) {
        document = SchemaDocument(root: root)
        var kinds: [GroupVersionKind: String] = [:]
        for (name, schema) in root.value(at: "components.schemas")?.objectValue ?? [:] {
            for g in schema["x-kubernetes-group-version-kind"]?.arrayValue ?? [] {
                guard let kind = g["kind"]?.stringValue, let version = g["version"]?.stringValue else { continue }
                kinds[GroupVersionKind(group: g["group"]?.stringValue ?? "", version: version, kind: kind)] = name
            }
        }
        self.kinds = kinds
        cost = root.estimatedMemoryCost
    }

    func schema(for gvk: GroupVersionKind) -> JSONValue? {
        guard let name = kinds[gvk] else { return nil }
        return document.root.value(at: "components.schemas")?[name]
    }
}

extension JSONValue {
    /// A generous estimate of the heap an in-memory value holds: boxed payloads, string storage and dictionary buckets.
    /// The schema cache budgets with this; `SchemaCacheCalibrationTests` (Mac) checks it against the measured footprint.
    var estimatedMemoryCost: Int {
        switch self {
        case .null, .bool, .int, .double: return 48
        case .string(let s): return 96 + (s.utf8.count > 15 ? s.utf8.count : 0)
        case .array(let a): return 96 + a.reduce(0) { $0 + $1.estimatedMemoryCost + 24 }
        case .object(let o): return 128 + o.reduce(0) { $0 + 128 + ($1.key.utf8.count > 15 ? $1.key.utf8.count : 0) + $1.value.estimatedMemoryCost }
        }
    }

    /// Fast JSON parse (Foundation's `JSONSerialization`); the Codable path costs an exception per scalar.
    static func fastParse(_ data: Data) throws -> JSONValue {
        convert(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    private static func convert(_ any: Any) -> JSONValue {
        switch any {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            let d = n.doubleValue
            if d == d.rounded(), abs(d) < 9e15, !String(cString: n.objCType).contains("d") && !String(cString: n.objCType).contains("f") { return .int(n.intValue) }
            return .double(d)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map(convert))
        case let o as [String: Any]: return .object(o.mapValues(convert))
        default: return .null
        }
    }
}
