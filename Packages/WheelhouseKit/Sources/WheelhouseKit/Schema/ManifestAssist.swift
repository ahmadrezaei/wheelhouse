import Foundation

/// One suggestion in the editor's completion list.
public struct ManifestCompletion: Hashable, Sendable {
    public enum Kind: Sendable { case field, value, apiVersion, kind, reference }
    /// What the list shows.
    public var label: String
    /// What replaces the typed text.
    public var insertText: String
    /// The type for a field (`string`, `[]Container`), or what a reference is.
    public var detail: String?
    public var documentation: String?
    public var kind: Kind

    public init(label: String, insertText: String, detail: String?, documentation: String?, kind: Kind) {
        self.label = label
        self.insertText = insertText
        self.detail = detail
        self.documentation = documentation
        self.kind = kind
    }
}

public struct ManifestCompletionResult: Sendable {
    /// The UTF-16 range the chosen item replaces.
    public var range: NSRange
    public var items: [ManifestCompletion]

    public init(range: NSRange, items: [ManifestCompletion]) {
        self.range = range
        self.items = items
    }
}

/// Documentation for the field under the pointer.
public struct ManifestHover: Hashable, Sendable {
    public var title: String
    public var type: String
    public var required: Bool
    public var documentation: String?
    public var choices: [String]
    public var range: NSRange
}

/// The reference kinds the editor can complete from the cluster.
public enum ReferenceKind: String, Sendable, CaseIterable {
    case configMap, secret, serviceAccount, persistentVolumeClaim, priorityClass, storageClass

    var resourceKind: ResourceKind {
        switch self {
        case .configMap: .configMap
        case .secret: .secret
        case .serviceAccount: .serviceAccount
        case .persistentVolumeClaim: .persistentVolumeClaim
        case .storageClass: .storageClass
        case .priorityClass: .custom(group: "scheduling.k8s.io", version: "v1", kind: "PriorityClass", plural: "priorityclasses", namespaced: false)
        }
    }

    var namespaced: Bool { resourceKind.namespaced }

    /// Which reference a field holds, from its key and the key of its parent mapping.
    static func of(key: String, parent: String?) -> ReferenceKind? {
        switch key {
        case "serviceAccountName", "serviceAccount": return .serviceAccount
        case "priorityClassName": return .priorityClass
        case "storageClassName": return .storageClass
        case "claimName": return .persistentVolumeClaim
        case "secretName": return .secret
        case "name":
            switch parent {
            case "secretRef", "secretKeyRef", "secret", "imagePullSecrets": return .secret
            case "configMapRef", "configMapKeyRef", "configMap": return .configMap
            case "persistentVolumeClaim": return .persistentVolumeClaim
            default: return nil
            }
        default: return nil
        }
    }
}

/// Names of cluster objects for reference completion. Only names are used. It lists metadata (`PartialObjectMetadata`), never `data`; metadata annotations can carry
/// values (for example `last-applied-configuration`), so nothing but `name` is read from the answer.
public struct ClusterReferences: Sendable {
    public var names: @Sendable (ReferenceKind, String?) async -> [String]

    public init(names: @escaping @Sendable (ReferenceKind, String?) async -> [String]) { self.names = names }

    public init(client: any KubeClientProtocol) {
        self.init { kind, namespace in
            let list = try? await client.listMetadata(kind: kind.resourceKind, namespace: kind.namespaced ? namespace : nil, labelSelector: nil, limit: 500)
            return (list?.items.map(\.name) ?? []).sorted()
        }
    }
}

/// Completion and hover over a document and a schema.
public enum ManifestAssist {
    /// The schema at the root of the cursor's document and how to read it.
    public struct Target: Sendable {
        public var engine: JSONSchemaEngine
        public var root: JSONValue
        public init(engine: JSONSchemaEngine, root: JSONValue) {
            self.engine = engine
            self.root = root
        }
        public init(_ kind: KindSchema) { self.init(engine: kind.engine, root: kind.schema) }
    }

    // MARK: Completion

    /// Completions at `offset` (UTF-16) of `text`. `known` lists the kinds the cluster serves (for `apiVersion` and `kind`).
    public static func completions(text: String, offset: Int, schemas: (any ManifestSchemaProviding)?, known: [GroupVersionKind] = [],
                                   references: ClusterReferences? = nil, defaultNamespace: String? = nil) async -> ManifestCompletionResult {
        let cursor = YAMLCursor.make(text: text, offset: offset)
        var target: Target?
        if let gvk = cursor.gvk, let schemas, let found = await schemas.kindSchema(for: gvk) { target = Target(found) }
        let namespace = cursor.namespace ?? defaultNamespace
        var refNames: [String] = []
        if cursor.isValue, let key = cursor.key, let rk = ReferenceKind.of(key: key, parent: cursor.parentKey), let references {
            refNames = await references.names(rk, namespace)
        }
        return complete(cursor: cursor, target: target, known: known, references: refNames)
    }

    /// The synchronous core, shared with ``ValuesSchemaHints``.
    static func complete(cursor: YAMLCursor, target: Target?, known: [GroupVersionKind], references: [String] = [], manifestFallback: Bool = true) -> ManifestCompletionResult {
        var items: [ManifestCompletion] = []
        if cursor.inFreeText { return ManifestCompletionResult(range: cursor.replaceRange, items: []) }
        if cursor.isValue {
            if cursor.path.count == 1, cursor.key == "apiVersion" {
                let versions = Set(known.filter { cursor.kind == nil || $0.kind == cursor.kind }.map(\.apiVersion)).sorted()
                items = versions.map { ManifestCompletion(label: $0, insertText: $0, detail: "apiVersion", documentation: nil, kind: .apiVersion) }
            } else if cursor.path.count == 1, cursor.key == "kind" {
                let kinds = Set(known.filter { cursor.apiVersion == nil || $0.apiVersion == cursor.apiVersion }.map(\.kind)).sorted()
                items = kinds.map { ManifestCompletion(label: $0, insertText: $0, detail: "kind", documentation: nil, kind: .kind) }
            } else if let target, let field = target.engine.schema(at: cursor.path, from: target.root) {
                items = target.engine.valueChoices(of: field).map { ManifestCompletion(label: $0, insertText: $0, detail: nil, documentation: nil, kind: .value) }
            }
            items += references.map { ManifestCompletion(label: $0, insertText: $0, detail: "name", documentation: nil, kind: .reference) }
        } else if let target, let parent = target.engine.schema(at: cursor.path, from: target.root) {
            items = target.engine.propertyList(of: parent).filter { !cursor.siblings.contains($0.name) }.map {
                ManifestCompletion(label: $0.name, insertText: "\($0.name): ", detail: $0.required ? "\($0.type) · required" : $0.type, documentation: $0.description, kind: .field)
            }
        } else if cursor.path.isEmpty, manifestFallback {
            items = ["apiVersion", "kind", "metadata", "spec"].filter { !cursor.siblings.contains($0) }.map {
                ManifestCompletion(label: $0, insertText: "\($0): ", detail: nil, documentation: nil, kind: .field)
            }
        }
        let typed = cursor.prefix.lowercased()
        if !typed.isEmpty {
            let starts = items.filter { $0.label.lowercased().hasPrefix(typed) }
            items = starts.isEmpty ? items.filter { $0.label.lowercased().contains(typed) } : starts
        }
        // A value already complete needs no suggestion.
        if cursor.isValue, items.count == 1, items[0].label == cursor.prefix { items = [] }
        return ManifestCompletionResult(range: cursor.replaceRange, items: items)
    }

    // MARK: Hover

    /// Documentation for the key under `offset`, nil when the pointer is not over a known field.
    public static func hover(text: String, offset: Int, schemas: (any ManifestSchemaProviding)?) async -> ManifestHover? {
        let cursor = YAMLCursor.make(text: text, offset: offset)
        guard let gvk = cursor.gvk, let schemas, let found = await schemas.kindSchema(for: gvk) else { return nil }
        return hover(text: text, offset: offset, target: Target(found))
    }

    static func hover(text: String, offset: Int, target: Target) -> ManifestHover? {
        let table = TextLineTable(text)
        let lines = text.yamlLines
        let n = table.lineIndex(containing: offset)
        guard lines.indices.contains(n) else { return nil }
        let shape = YAMLLineShape(lines[n])
        guard let key = shape.key else { return nil }
        let col = offset - table.starts[n]
        guard col >= shape.contentColumn, col <= shape.contentColumn + shape.keyLength else { return nil }

        // The path of the key: everything before this line, then its own structure.
        let cursorAtKey = YAMLCursor.make(text: text, offset: table.starts[n] + shape.contentColumn + min(1, shape.keyLength))
        let parent = cursorAtKey.path
        guard let field = target.engine.schema(at: parent + [.key(key)], from: target.root) else { return nil }
        return ManifestHover(
            title: key, type: target.engine.typeLabel(of: field), required: isRequired(key, in: parent, target: target),
            documentation: target.engine.description(of: field), choices: target.engine.valueChoices(of: field),
            range: NSRange(location: table.starts[n] + shape.contentColumn, length: shape.keyLength))
    }

    private static func isRequired(_ key: String, in parent: [SchemaPathSegment], target: Target) -> Bool {
        guard let schema = target.engine.schema(at: parent, from: target.root) else { return false }
        return target.engine.flatten(schema, depth: 0).required.contains(key)
    }
}
