import Foundation

/// A Kubernetes resource quantity such as `250m`, `128Mi`, `1.5`, `2e3`, `4G`.
public struct Quantity: Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let raw: String

    public init(_ raw: String) { self.raw = raw }
    public init(stringLiteral value: String) { raw = value }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { raw = s }
        else if let i = try? c.decode(Int.self) { raw = String(i) }
        else if let d = try? c.decode(Double.self) { raw = String(d) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid quantity") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
    public var description: String { raw }

    /// Value in base units (cores for CPU, bytes for memory/storage, plain count otherwise).
    public var value: Double? { Quantity.parse(raw) }
    public var millicores: Double { (value ?? 0) * 1000 }
    public var cores: Double { value ?? 0 }
    public var bytes: Double { value ?? 0 }

    static let suffixes: [(String, Double)] = [
        ("Ki", 1024), ("Mi", pow(1024, 2)), ("Gi", pow(1024, 3)), ("Ti", pow(1024, 4)),
        ("Pi", pow(1024, 5)), ("Ei", pow(1024, 6)),
        ("n", 1e-9), ("u", 1e-6), ("m", 1e-3),
        ("k", 1e3), ("K", 1e3), ("M", 1e6), ("G", 1e9), ("T", 1e12), ("P", 1e15), ("E", 1e18),
    ]

    /// Parses a quantity string into base units. Returns nil if malformed.
    public static func parse(_ input: String) -> Double? {
        let s = input.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        var idx = s.startIndex
        if s[idx] == "+" || s[idx] == "-" { idx = s.index(after: idx) }
        let numberStart = idx
        while idx < s.endIndex, s[idx].isASCII, s[idx].isNumber || s[idx] == "." { idx = s.index(after: idx) }
        guard idx > numberStart, let number = Double(s[s.startIndex..<idx]) else { return nil }
        let rest = String(s[idx...])
        if rest.isEmpty { return number }
        // Decimal exponent: e3, E-2 (an "E" alone is the exa suffix).
        if let first = rest.first, first == "e" || first == "E", rest.count > 1,
           let exp = Int(rest.dropFirst()) {
            return number * pow(10, Double(exp))
        }
        guard let factor = suffixes.first(where: { $0.0 == rest })?.1 else { return nil }
        return number * factor
    }

    // MARK: Formatting

    public static func formatCPU(cores: Double) -> String {
        if cores >= 1 { return cores.formatted(.number.precision(.fractionLength(0...2))) }
        return "\(Int((cores * 1000).rounded()))m"
    }

    public static func formatMillicores(_ m: Double) -> String { formatCPU(cores: m / 1000) }

    public static func formatBytes(_ bytes: Double, binary: Bool = true) -> String {
        let base: Double = binary ? 1024 : 1000
        let units = binary ? ["B", "Ki", "Mi", "Gi", "Ti", "Pi"] : ["B", "kB", "MB", "GB", "TB", "PB"]
        var v = abs(bytes)
        var i = 0
        while v >= base, i < units.count - 1 { v /= base; i += 1 }
        let sign = bytes < 0 ? "-" : ""
        if i == 0 { return "\(sign)\(Int(v))\(units[0])" }
        return "\(sign)\(v.formatted(.number.precision(.fractionLength(0...1))))\(units[i])"
    }
}

public typealias ResourceList = [String: Quantity]

public extension Dictionary where Key == String, Value == Quantity {
    var cpuCores: Double? { self["cpu"]?.value }
    var memoryBytes: Double? { self["memory"]?.value }
}
