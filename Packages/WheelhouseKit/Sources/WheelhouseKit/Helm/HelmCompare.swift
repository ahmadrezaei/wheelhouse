import CryptoKit
import Foundation

public extension HelmManifestObject {
    /// YAML for display. A Secret's `data` and `stringData` values are hidden unless `revealed`, because a release manifest
    /// carries them in clear (or base64).
    func displayYAML(revealed: Bool) -> String {
        guard kind == "Secret", !revealed else { return yaml }
        var v = value
        for key in ["data", "stringData"] {
            if case .object(let map)? = v[key] { v[key] = .object(map.mapValues { _ in .string(HelmValuesMask.placeholder) }) }
        }
        return YAMLCodec.dump(v)
    }
}

public extension HelmValuesMask {
    /// Like ``masked(_:)``, but a masked value carries a short fingerprint, so comparing two revisions still shows that a secret
    /// changed without showing it. Four hex digits of a SHA-256 leak nothing usable.
    static func maskedForComparison(_ value: JSONValue) -> JSONValue { fingerprinted(value, inherited: false) }

    private static func fingerprinted(_ value: JSONValue, inherited: Bool) -> JSONValue {
        func tag(_ text: String) -> JSONValue {
            let digest = SHA256.hash(data: Data(text.utf8)).prefix(2).map { String(format: "%02x", $0) }.joined()
            return .string("\(placeholder) #\(digest)")
        }
        switch value {
        case .object(let o): return .object(o.reduce(into: [:]) { $0[$1.key] = fingerprinted($1.value, inherited: inherited || isSensitiveKey($1.key)) })
        case .array(let a): return .array(a.map { fingerprinted($0, inherited: inherited) })
        case .string(let s): return inherited && !s.isEmpty ? tag(s) : value
        case .int(let i): return inherited ? tag(String(i)) : value
        case .double(let d): return inherited ? tag(String(d)) : value
        default: return value
        }
    }
}

/// The difference between two revisions of a release: user values, and the manifest object by object (`kind/namespace/name`).
public struct HelmComparison: Sendable {
    public enum Change: Sendable, Hashable { case added, removed, changed, unchanged }

    public struct ObjectChange: Sendable, Identifiable, Hashable {
        public var id: String
        public var change: Change
        public var diff: [DiffLine]
        public var stats: LineDiff.Stats
    }

    public var valuesDiff: [DiffLine]
    public var valuesStats: LineDiff.Stats
    public var objects: [ObjectChange]
    public var added: Int { objects.filter { $0.change == .added }.count }
    public var removed: Int { objects.filter { $0.change == .removed }.count }
    public var changed: Int { objects.filter { $0.change == .changed }.count }

    /// `old` to `new`. Values are compared in their fingerprinted masked form; Secret objects never show their data.
    public static func compare(old: HelmRelease, new: HelmRelease) -> HelmComparison {
        func values(_ r: HelmRelease) -> String {
            guard case .object(let o) = r.config, !o.isEmpty else { return "" }
            return YAMLCodec.dump(HelmValuesMask.maskedForComparison(r.config))
        }
        let valuesDiff = LineDiff.diff(old: values(old), new: values(new))

        func index(_ r: HelmRelease) -> [(key: String, text: String)] {
            HelmManifest.objects(in: r.manifest).map { o in
                (key: "\(o.kind)/\(o.namespace ?? r.namespace)/\(o.name)", text: o.displayYAML(revealed: false))
            }
        }
        let before = index(old), after = index(new)
        let beforeByKey = Dictionary(before.map { ($0.key, $0.text) }, uniquingKeysWith: { a, _ in a })
        let afterByKey = Dictionary(after.map { ($0.key, $0.text) }, uniquingKeysWith: { a, _ in a })
        var order: [String] = []
        for k in before.map(\.key) + after.map(\.key) where !order.contains(k) { order.append(k) }

        let objects = order.map { key -> ObjectChange in
            let old = beforeByKey[key], new = afterByKey[key]
            let diff = LineDiff.diff(old: old ?? "", new: new ?? "")
            let change: Change = old == nil ? .added : new == nil ? .removed : old == new ? .unchanged : .changed
            return ObjectChange(id: key, change: change, diff: diff, stats: LineDiff.stats(diff))
        }
        return HelmComparison(valuesDiff: valuesDiff, valuesStats: LineDiff.stats(valuesDiff), objects: objects)
    }
}
