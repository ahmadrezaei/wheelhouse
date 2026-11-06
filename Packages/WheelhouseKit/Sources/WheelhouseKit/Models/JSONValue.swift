import Foundation

/// A generic JSON value used for unknown / custom resources and raw editing.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

extension JSONValue: ExpressibleByStringInterpolation, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    public init(nilLiteral: ()) { self = .null }
}

public extension JSONValue {
    var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    var intValue: Int? {
        switch self {
        case .int(let i): i
        case .double(let d): Int(exactly: d.rounded())
        default: nil
        }
    }
    var doubleValue: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        case .string(let s): Double(s)
        default: nil
        }
    }
    var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
    var isNull: Bool { if case .null = self { true } else { false } }

    subscript(key: String) -> JSONValue? {
        get { objectValue?[key] }
        set {
            guard case .object(var o) = self else { return }
            o[key] = newValue
            self = .object(o)
        }
    }
    subscript(index: Int) -> JSONValue? {
        guard case .array(let a) = self, a.indices.contains(index) else { return nil }
        return a[index]
    }

    /// Walks a dotted path such as `metadata.labels` (no array indexing).
    func value(at path: String) -> JSONValue? {
        var current: JSONValue? = self
        for part in path.split(separator: ".") {
            current = current?[String(part)]
        }
        return current
    }

    /// Sets a value at a dotted path, creating intermediate objects.
    mutating func setValue(_ value: JSONValue?, at path: String) {
        let parts = path.split(separator: ".").map(String.init)
        self = Self.setting(self, parts[...], value)
    }

    private static func setting(_ node: JSONValue, _ parts: ArraySlice<String>, _ value: JSONValue?) -> JSONValue {
        guard let head = parts.first else { return value ?? .null }
        var object = node.objectValue ?? [:]
        let rest = parts.dropFirst()
        if rest.isEmpty {
            object[head] = value
        } else {
            object[head] = setting(object[head] ?? .object([:]), rest, value)
        }
        return .object(object)
    }

    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func data(pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    func jsonString(pretty: Bool = false) -> String {
        (try? data(pretty: pretty)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    /// Decodes this value into a typed model.
    func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try KubeJSON.decoder.decode(T.self, from: data())
    }
}
