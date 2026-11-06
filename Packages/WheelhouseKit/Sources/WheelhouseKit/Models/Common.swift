import Foundation

public typealias ClusterID = String

// MARK: - JSON coding

public enum KubeJSON {
    private static func parseDate(_ s: String) -> Date? {
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let d = try? withFraction.parse(s) { return d }
        return try? Date.ISO8601FormatStyle().parse(s)
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = parseDate(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid date \(s)")
            }
            return date
        }
        return d
    }

    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(.iso8601))
        }
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }
}

// MARK: - Lenient decoding of missing collections

public protocol EmptyInitializable { init() }
extension Array: EmptyInitializable {}
extension Dictionary: EmptyInitializable {}
extension String: EmptyInitializable {}

/// Property wrapper that decodes a missing or `null` collection as empty, so models can stay non-optional.
@propertyWrapper
public struct Lenient<Value: Codable & Sendable & Hashable & EmptyInitializable>: Codable, Sendable, Hashable {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    public init() { wrappedValue = Value() }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        wrappedValue = c.decodeNil() ? Value() : try c.decode(Value.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    public func decode<V>(_ type: Lenient<V>.Type, forKey key: Key) throws -> Lenient<V> {
        try decodeIfPresent(type, forKey: key) ?? Lenient()
    }
}

// MARK: - Core meta types

public struct OwnerReference: Codable, Hashable, Sendable {
    public var apiVersion: String?
    public var kind: String
    public var name: String
    public var uid: String?
    public var controller: Bool?
    public var blockOwnerDeletion: Bool?
}

public struct ObjectMeta: Codable, Hashable, Sendable {
    public var name: String
    public var generateName: String?
    public var namespace: String?
    public var uid: String?
    public var resourceVersion: String?
    public var generation: Int?
    public var creationTimestamp: Date?
    public var deletionTimestamp: Date?
    @Lenient public var labels: [String: String]
    @Lenient public var annotations: [String: String]
    @Lenient public var ownerReferences: [OwnerReference]
    @Lenient public var finalizers: [String]

    public init(name: String = "", namespace: String? = nil, uid: String? = nil, labels: [String: String] = [:],
                annotations: [String: String] = [:], creationTimestamp: Date? = nil) {
        self.name = name
        self.namespace = namespace
        self.uid = uid
        self.creationTimestamp = creationTimestamp
        self.labels = labels
        self.annotations = annotations
        self.ownerReferences = []
        self.finalizers = []
    }

    enum CodingKeys: String, CodingKey {
        case name, generateName, namespace, uid, resourceVersion, generation, creationTimestamp, deletionTimestamp
        case labels, annotations, ownerReferences, finalizers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        generateName = try c.decodeIfPresent(String.self, forKey: .generateName)
        namespace = try c.decodeIfPresent(String.self, forKey: .namespace)
        uid = try c.decodeIfPresent(String.self, forKey: .uid)
        resourceVersion = try c.decodeIfPresent(String.self, forKey: .resourceVersion)
        generation = try c.decodeIfPresent(Int.self, forKey: .generation)
        creationTimestamp = try c.decodeIfPresent(Date.self, forKey: .creationTimestamp)
        deletionTimestamp = try c.decodeIfPresent(Date.self, forKey: .deletionTimestamp)
        labels = try c.decode(Lenient<[String: String]>.self, forKey: .labels).wrappedValue
        annotations = try c.decode(Lenient<[String: String]>.self, forKey: .annotations).wrappedValue
        ownerReferences = try c.decode(Lenient<[OwnerReference]>.self, forKey: .ownerReferences).wrappedValue
        finalizers = try c.decode(Lenient<[String]>.self, forKey: .finalizers).wrappedValue
    }

    /// Controller owner reference, if any.
    public var controller: OwnerReference? { ownerReferences.first { $0.controller == true } ?? ownerReferences.first }
}

public struct ListMeta: Codable, Hashable, Sendable {
    public var resourceVersion: String?
    public var `continue`: String?
    public var remainingItemCount: Int?
}

public struct LabelSelectorRequirement: Codable, Hashable, Sendable {
    public var key: String
    public var `operator`: String
    @Lenient public var values: [String]

    public init(key: String, operator op: String, values: [String] = []) {
        self.key = key
        self.operator = op
        self.values = values
    }
}

public struct LabelSelector: Codable, Hashable, Sendable {
    @Lenient public var matchLabels: [String: String]
    @Lenient public var matchExpressions: [LabelSelectorRequirement]

    public init(matchLabels: [String: String] = [:]) {
        self.matchLabels = matchLabels
        self.matchExpressions = []
    }

    /// Selector string for `labelSelector=` query parameters (equality + set-based).
    public var queryString: String {
        var parts = matchLabels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        for e in matchExpressions {
            switch e.operator {
            case "In": parts.append("\(e.key) in (\(e.values.joined(separator: ",")))")
            case "NotIn": parts.append("\(e.key) notin (\(e.values.joined(separator: ",")))")
            case "Exists": parts.append(e.key)
            case "DoesNotExist": parts.append("!\(e.key)")
            default: break
            }
        }
        return parts.joined(separator: ",")
    }
}

public struct Condition: Codable, Hashable, Sendable, Identifiable {
    public var type: String
    public var status: String
    public var reason: String?
    public var message: String?
    public var lastTransitionTime: Date?
    public var lastProbeTime: Date?
    public var lastUpdateTime: Date?
    public var id: String { type }
    public var isTrue: Bool { status == "True" }
}

public struct ObjectReference: Codable, Hashable, Sendable {
    public var apiVersion: String?
    public var kind: String?
    public var name: String?
    public var namespace: String?
    public var uid: String?
    public var fieldPath: String?
}

// MARK: - Protocols & generic wrappers

/// A Kubernetes object that can be listed/watched through ``KubeClientProtocol``.
public protocol KubeObject: Codable, Sendable, Identifiable, Hashable {
    static var resourceKind: ResourceKind { get }
    var metadata: ObjectMeta { get }
}

public extension KubeObject {
    var id: String { metadata.uid ?? "\(metadata.namespace ?? "")/\(metadata.name)" }
    var name: String { metadata.name }
    var namespace: String? { metadata.namespace }
    var creationTimestamp: Date? { metadata.creationTimestamp }
    func age(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(metadata.creationTimestamp ?? now) }
}

public struct KubeList<Item: Codable & Sendable>: Codable, Sendable {
    public var apiVersion: String?
    public var kind: String?
    public var metadata: ListMeta
    public var items: [Item]
    /// Number of items the server returned that could not be decoded into `Item` (skipped).
    public var skippedItems: Int

    public init(items: [Item], resourceVersion: String? = nil) {
        self.metadata = ListMeta(resourceVersion: resourceVersion)
        self.items = items
        self.skippedItems = 0
    }

    enum CodingKeys: String, CodingKey { case apiVersion, kind, metadata, items }

    private struct Failable: Decodable {
        let value: Item?
        init(from decoder: Decoder) throws { value = try? Item(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiVersion = try c.decodeIfPresent(String.self, forKey: .apiVersion)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        metadata = try c.decodeIfPresent(ListMeta.self, forKey: .metadata) ?? ListMeta()
        let raw = try c.decodeIfPresent([Failable].self, forKey: .items) ?? []
        items = raw.compactMap(\.value)
        skippedItems = raw.count - items.count
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(apiVersion, forKey: .apiVersion)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encode(metadata, forKey: .metadata)
        try c.encode(items, forKey: .items)
    }
}

extension KubeList: Equatable where Item: Equatable {}
extension KubeList: Hashable where Item: Hashable {}

/// Any resource as raw JSON with its metadata decoded (for CRs and generic lists).
public struct Unstructured: KubeObject {
    public static var resourceKind: ResourceKind { .unknown }
    public var apiVersion: String?
    public var kind: String?
    public var metadata: ObjectMeta
    public var raw: JSONValue

    public init(raw: JSONValue) {
        self.raw = raw
        self.apiVersion = raw["apiVersion"]?.stringValue
        self.kind = raw["kind"]?.stringValue
        self.metadata = (try? raw["metadata"]?.decode(ObjectMeta.self)) ?? ObjectMeta()
    }
    public init(from decoder: Decoder) throws {
        self.init(raw: try JSONValue(from: decoder))
    }
    public func encode(to encoder: Encoder) throws { try raw.encode(to: encoder) }
}

/// metav1.Status
public struct Status: Codable, Hashable, Sendable {
    public struct Cause: Codable, Hashable, Sendable {
        public var reason: String?
        public var message: String?
        public var field: String?
    }
    public struct Details: Codable, Hashable, Sendable {
        public var name: String?
        public var group: String?
        public var kind: String?
        public var uid: String?
        public var retryAfterSeconds: Int?
        @Lenient public var causes: [Cause]
    }
    public var apiVersion: String?
    public var kind: String?
    public var status: String?
    public var message: String?
    public var reason: String?
    public var details: Details?
    public var code: Int?

    public init(status: String? = nil, message: String? = nil, reason: String? = nil, code: Int? = nil, details: Details? = nil) {
        self.status = status
        self.message = message
        self.reason = reason
        self.code = code
        self.details = details
    }
}

/// Pointer to one object in one cluster; also the identity used for multi-window scenes and routes.
public struct ResourceRef: Hashable, Codable, Sendable, Identifiable {
    public var clusterID: ClusterID
    public var kind: ResourceKind
    public var namespace: String?
    public var name: String
    public var id: String { "\(clusterID)/\(kind.id)/\(namespace ?? "-")/\(name)" }

    public init(clusterID: ClusterID, kind: ResourceKind, namespace: String? = nil, name: String) {
        self.clusterID = clusterID
        self.kind = kind
        self.namespace = namespace
        self.name = name
    }

    public init<T: KubeObject>(clusterID: ClusterID, object: T) {
        self.init(clusterID: clusterID, kind: T.resourceKind, namespace: object.metadata.namespace, name: object.metadata.name)
    }
}
