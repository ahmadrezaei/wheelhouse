import Foundation

/// Evaluates a pack's data against objects: status rules, columns, related objects and health rules. Pure functions of the object
/// JSON; nothing here reads a file, the network or the cluster.
public enum RiggingEngine {
    // MARK: Conditions

    /// Whether `condition` holds for `object`. A duration (`for`) needs the condition's `lastTransitionTime` to be at least that old.
    public static func matches(_ condition: RiggingPack.Condition, in object: JSONValue, now: Date = Date()) -> Bool {
        if let type = condition.condition {
            guard let entry = conditionEntry(type, in: object), entry["status"]?.stringValue == (condition.status ?? "True") else { return false }
            guard let wait = condition.duration else { return true }
            guard let seconds = RiggingPackValidator.durationSeconds(wait), let since = entry["lastTransitionTime"]?.stringValue.flatMap(parseDate) else { return false }
            return now.timeIntervalSince(since) >= seconds
        }
        guard let text = condition.path, let path = try? JSONPathSubset(text) else { return false }
        let values = path.evaluate(object)
        if let exists = condition.exists { return values.isEmpty != exists }
        if let equals = condition.equals { return values.contains { JSONPathSubset.scalarText($0) == equals } }
        if let options = condition.oneOf { return values.contains { JSONPathSubset.scalarText($0).map(options.contains) ?? false } }
        return false
    }

    private static func conditionEntry(_ type: String, in object: JSONValue) -> JSONValue? {
        object.value(at: "status.conditions")?.arrayValue?.first { $0["type"]?.stringValue == type }
    }

    static func parseDate(_ s: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s)) ?? (try? Date.ISO8601FormatStyle().parse(s))
    }

    // MARK: Views

    /// The tone and label of the first status rule that matches (the order in the pack is the priority); neutral when none does.
    public static func tone(for view: RiggingPack.ViewSpec, object: JSONValue, now: Date = Date()) -> (tone: RiggingPack.Tone, label: String?) {
        for rule in view.status ?? [] where matches(rule.when, in: object, now: now) { return (rule.tone, rule.label) }
        return (.neutral, nil)
    }

    /// The text of one column for one object.
    public static func cell(_ column: RiggingPack.Column, object: JSONValue, now: Date = Date()) -> String {
        guard let path = try? JSONPathSubset(column.path), let value = path.first(in: object) else { return "" }
        switch column.format ?? .text {
        case .text:
            if case .array(let items) = value { return items.compactMap(JSONPathSubset.scalarText).joined(separator: ", ") }
            return JSONPathSubset.scalarText(value) ?? ""
        case .age:
            guard let text = value.stringValue, let date = parseDate(text) else { return "" }
            return age(since: date, now: now)
        case .number: return JSONPathSubset.scalarText(value) ?? ""
        case .bool:
            switch value {
            case .bool(let b): return b ? "Yes" : "No"
            case .string(let s): return ["true", "True"].contains(s) ? "Yes" : (["false", "False"].contains(s) ? "No" : s)
            default: return ""
            }
        }
    }

    /// A short age such as `3d`, `5h`, `12m`; a date in the future shows as "in 3d".
    public static func age(since date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        let magnitude = abs(seconds)
        let text: String
        switch magnitude {
        case ..<60: text = "\(magnitude)s"
        case ..<3600: text = "\(magnitude / 60)m"
        case ..<86_400: text = "\(magnitude / 3600)h"
        default: text = "\(magnitude / 86_400)d"
        }
        return seconds < 0 ? "in \(text)" : text
    }

    /// A related object a view points at: its kind and name, in the namespace of the object unless the view says otherwise.
    public struct RelatedRef: Hashable, Sendable {
        public var label: String
        public var group: String
        public var kind: String
        public var name: String
        public var namespace: String?
    }

    /// The related objects of `object`. A name or namespace that is not a valid Kubernetes name is dropped.
    public static func related(of object: JSONValue, view: RiggingPack.ViewSpec) -> [RelatedRef] {
        let ownNamespace = object.value(at: "metadata.namespace")?.stringValue
        return (view.related ?? []).compactMap { rel in
            guard let path = try? JSONPathSubset(rel.nameFrom), let name = path.text(in: object), KubeNames.isObjectName(name) else { return nil }
            var namespace = ownNamespace
            if let from = rel.namespaceFrom {
                guard let p = try? JSONPathSubset(from), let ns = p.text(in: object), KubeNames.isDNSLabel(ns) else { return nil }
                namespace = ns
            }
            return RelatedRef(label: rel.label, group: rel.group ?? "", kind: rel.kind, name: name, namespace: namespace)
        }
    }

    // MARK: Health rules

    public struct Finding: Hashable, Sendable {
        public var packName: String
        public var group: String
        public var kind: String
        public var name: String
        public var namespace: String?
        public var tone: RiggingPack.HealthRule.Tone
        public var message: String
        public var since: Date?
    }

    /// The objects of `rule.for` that break `rule`, with the rendered message. A message that cannot be rendered safely is skipped
    /// (the finding then reads "<Kind> <name>" instead).
    public static func findings(of rule: RiggingPack.HealthRule, pack: RiggingPack, objects: [JSONValue], cluster: String, now: Date = Date()) -> [Finding] {
        let fields = pack.fields(for: rule.for)
        let template = try? RiggingTemplate(rule.message, mode: .plain, allowed: Set(["name", "namespace", "cluster", "kind"]).union(fields.map(\.name)))
        return objects.compactMap { object in
            guard matches(rule.when, in: object, now: now) else { return nil }
            let name = object.value(at: "metadata.name")?.stringValue ?? ""
            let namespace = object.value(at: "metadata.namespace")?.stringValue
            let values = RiggingValues.make(subject: .init(name: name, namespace: namespace, kind: rule.for.kind, raw: object), cluster: cluster, fields: fields)
            let message = (try? template?.render(values)) ?? "\(rule.for.kind) \(name)"
            var since: Date?
            if let type = rule.when.condition, let t = conditionEntry(type, in: object)?["lastTransitionTime"]?.stringValue { since = parseDate(t) }
            return Finding(packName: pack.metadata.name, group: rule.for.group, kind: rule.for.kind, name: name, namespace: namespace,
                           tone: rule.tone, message: message, since: since)
        }
    }
}
