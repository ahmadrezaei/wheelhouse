import Foundation
import Yams

// MARK: - Label selectors

public enum LabelSelectorSyntax {
    /// Returns a human-readable problem with a `labelSelector` string, or nil when it is valid (`app=web,tier in (api,worker),!canary`).
    public static func validate(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        var depth = 0
        var current = ""
        var clauses: [String] = []
        for ch in trimmed {
            if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1; if depth < 0 { return "Unbalanced parentheses" } }
            if ch == ",", depth == 0 { clauses.append(current); current = "" } else { current.append(ch) }
        }
        if depth != 0 { return "Unbalanced parentheses" }
        clauses.append(current)
        for raw in clauses {
            let c = raw.trimmingCharacters(in: .whitespaces)
            if c.isEmpty { return "Empty requirement (stray comma)" }
            if let r = c.range(of: #"^(\S+)\s+(in|notin)\s+\((.*)\)$"#, options: .regularExpression) {
                _ = r
                let parts = c.split(separator: " ", maxSplits: 1).map(String.init)
                if !validKey(parts[0]) { return "Invalid key “\(parts[0])”" }
                continue
            }
            if c.contains(" in ") || c.contains(" notin ") { return "Use `key in (a,b)` with parentheses" }
            if let op = ["!=", "==", "="].first(where: { c.contains($0) }) {
                let parts = c.components(separatedBy: op)
                guard parts.count == 2 else { return "Invalid requirement “\(c)”" }
                if !validKey(parts[0]) { return "Invalid key “\(parts[0])”" }
                if !parts[1].isEmpty, parts[1].range(of: #"^[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?$"#, options: .regularExpression) == nil { return "Invalid value “\(parts[1])”" }
                continue
            }
            let key = c.hasPrefix("!") ? String(c.dropFirst()) : c
            if !validKey(key) { return "Invalid requirement “\(c)”" }
        }
        return nil
    }

    static func validKey(_ k: String) -> Bool {
        k.range(of: #"^([a-z0-9]([-a-z0-9.]*[a-z0-9])?/)?[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil
    }

    /// Client-side evaluation of a typed `LabelSelector` against labels (used for PDB / Service matching).
    public static func matches(_ selector: LabelSelector?, labels: [String: String]) -> Bool {
        guard let selector else { return true }
        for (k, v) in selector.matchLabels where labels[k] != v { return false }
        for e in selector.matchExpressions {
            switch e.operator {
            case "In": if !(labels[e.key].map(e.values.contains) ?? false) { return false }
            case "NotIn": if labels[e.key].map(e.values.contains) ?? false { return false }
            case "Exists": if labels[e.key] == nil { return false }
            case "DoesNotExist": if labels[e.key] != nil { return false }
            default: break
            }
        }
        return true
    }

    /// `matchLabels` map → `k=v,k2=v2` selector string (Service.spec.selector).
    public static func query(from labels: [String: String]) -> String {
        labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }
}

// MARK: - Scale policy

public enum ScalePolicy {
    /// Scaling to zero or reducing by more than half is "disruptive" (typed confirmation on production).
    public static func isDisruptive(from current: Int, to target: Int) -> Bool {
        target == 0 && current > 0 || (current > 0 && Double(current - target) / Double(current) > 0.5)
    }
}

// MARK: - Rollout history & rollback

public struct RolloutRevision: Identifiable, Hashable, Sendable {
    public var revision: Int
    public var replicaSetName: String
    public var images: [String]
    public var changeCause: String?
    public var created: Date?
    public var replicas: Int
    public var readyReplicas: Int
    public var isCurrent: Bool
    public var template: JSONValue?
    /// The ReplicaSet's annotations (rollback copies the non-bookkeeping ones onto the Deployment, like `kubectl rollout undo`).
    public var annotations: [String: String] = [:]
    public var id: String { replicaSetName }
}

public enum RolloutHistory {
    public static let revisionAnnotation = "deployment.kubernetes.io/revision"

    /// Revisions of a Deployment, newest first, built from the ReplicaSets it owns.
    public static func revisions(deployment: Unstructured, replicaSets: [Unstructured]) -> [RolloutRevision] {
        let current = Int(deployment.metadata.annotations[revisionAnnotation] ?? "")
        let owned = replicaSets.filter { rs in
            rs.metadata.ownerReferences.contains { $0.kind == "Deployment" && ($0.uid == nil || deployment.metadata.uid == nil ? $0.name == deployment.metadata.name : $0.uid == deployment.metadata.uid) }
        }
        return owned.compactMap { rs -> RolloutRevision? in
            guard let rev = Int(rs.metadata.annotations[revisionAnnotation] ?? "") else { return nil }
            let images = rs.array("spec.template.spec.containers").compactMap { $0["image"]?.stringValue }
            return RolloutRevision(revision: rev, replicaSetName: rs.metadata.name, images: images,
                                   changeCause: rs.metadata.annotations["kubernetes.io/change-cause"],
                                   created: rs.metadata.creationTimestamp, replicas: rs.int("status.replicas") ?? rs.int("spec.replicas") ?? 0,
                                   readyReplicas: rs.int("status.readyReplicas") ?? 0, isCurrent: rev == current,
                                   template: rs.raw.value(at: "spec.template"), annotations: rs.metadata.annotations)
        }.sorted { $0.revision > $1.revision }
    }

    /// Annotations `kubectl rollout undo` neither copies from the ReplicaSet nor drops from the Deployment.
    static let bookkeepingAnnotations: Set<String> = [
        "kubectl.kubernetes.io/last-applied-configuration", "deployment.kubernetes.io/revision", "deployment.kubernetes.io/revision-history",
        "deployment.kubernetes.io/desired-replicas", "deployment.kubernetes.io/max-replicas", "deprecated.deployment.rollback.to",
    ]

    /// The Deployment's pod template as the ReplicaSet stores it, minus the generated `pod-template-hash` label.
    static func normalizedTemplate(_ template: JSONValue?) -> JSONValue? {
        guard var template else { return nil }
        if var labels = template.value(at: "metadata.labels")?.objectValue {
            labels["pod-template-hash"] = nil
            template.setValue(.object(labels), at: "metadata.labels")
        }
        return template
    }

    /// Why a rollback is not possible right now (nil = fine). `kubectl rollout undo` refuses paused Deployments.
    public static func rollbackBlocker(deployment: Unstructured) -> String? {
        deployment.bool("spec.paused") == true ? "This Deployment's rollout is paused. Resume the rollout first." : nil
    }

    /// True when the revision's pod template is already what the Deployment runs, so rolling back would change nothing.
    public static func matchesCurrentTemplate(_ revision: RolloutRevision, deployment: Unstructured) -> Bool {
        guard let rs = normalizedTemplate(revision.template), let cur = normalizedTemplate(deployment.raw.value(at: "spec.template")) else { return false }
        return rs == cur
    }

    /// JSON patch like `kubectl rollout undo`: replaces the pod template with the revision's (minus the generated `pod-template-hash`)
    /// and, when the Deployment's current annotations are given, its annotations with the Deployment's own bookkeeping ones plus the
    /// ReplicaSet's other annotations (e.g. `kubernetes.io/change-cause`).
    public static func rollbackPatch(to revision: RolloutRevision, deploymentAnnotations: [String: String]? = nil) -> KubePatch? {
        guard let template = normalizedTemplate(revision.template) else { return nil }
        var ops: [JSONValue] = [["op": "replace", "path": "/spec/template", "value": template]]
        if let deploymentAnnotations {
            var merged = deploymentAnnotations.filter { bookkeepingAnnotations.contains($0.key) }
            for (k, v) in revision.annotations where !bookkeepingAnnotations.contains(k) { merged[k] = v }
            ops.append(["op": "add", "path": "/metadata/annotations", "value": .object(merged.mapValues { .string($0) })])
        }
        return .json(ops)
    }
}

// MARK: - CronJob

public enum CronJobTrigger {
    public static let instantiateAnnotation = "cronjob.kubernetes.io/instantiate"

    /// `<cronjob>-manual-<yyMMddHHmmss>`, kept within the 63-character name limit.
    public static func jobName(cronJob: String, now: Date = Date()) -> String {
        let c = Calendar(identifier: .gregorian)
        let comps = c.dateComponents(in: TimeZone(identifier: "UTC") ?? .gmt, from: now)
        let stamp = String(format: "%02d%02d%02d%02d%02d%02d", (comps.year ?? 2000) % 100, comps.month ?? 1, comps.day ?? 1, comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0)
        let suffix = "-manual-\(stamp)"
        return String(cronJob.prefix(63 - suffix.count)) + suffix
    }

    /// Job object created from `spec.jobTemplate` (what `kubectl create job --from=cronjob/x` sends).
    public static func makeJob(cronJob: Unstructured, now: Date = Date()) -> JSONValue? {
        guard let spec = cronJob.raw.value(at: "spec.jobTemplate.spec") else { return nil }
        var annotations = cronJob.raw.value(at: "spec.jobTemplate.metadata.annotations")?.objectValue ?? [:]
        annotations[instantiateAnnotation] = "manual"
        let labels = cronJob.raw.value(at: "spec.jobTemplate.metadata.labels")?.objectValue ?? [:]
        var meta: [String: JSONValue] = [
            "name": .string(jobName(cronJob: cronJob.metadata.name, now: now)),
            "annotations": .object(annotations),
            "ownerReferences": [[
                "apiVersion": .string(cronJob.apiVersion ?? "batch/v1"), "kind": "CronJob", "name": .string(cronJob.metadata.name),
                "uid": .string(cronJob.metadata.uid ?? ""), "controller": true, "blockOwnerDeletion": true,
            ]],
        ]
        if let ns = cronJob.metadata.namespace { meta["namespace"] = .string(ns) }
        if !labels.isEmpty { meta["labels"] = .object(labels) }
        if cronJob.metadata.uid == nil { meta["ownerReferences"] = nil }
        return ["apiVersion": "batch/v1", "kind": "Job", "metadata": .object(meta), "spec": spec]
    }
}

/// Minimal 5-field cron evaluator for "describe" and "next runs" (UTC unless a timezone is applied by the caller).
public struct CronSchedule: Sendable {
    private let minutes: Set<Int>, hours: Set<Int>, days: Set<Int>, months: Set<Int>, weekdays: Set<Int>
    private let fields: [String]

    public init?(_ expression: String) {
        let macro: [String: String] = ["@hourly": "0 * * * *", "@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@weekly": "0 0 * * 0", "@monthly": "0 0 1 * *", "@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *"]
        let expr = macro[expression.trimmingCharacters(in: .whitespaces)] ?? expression
        let parts = expr.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 5,
              let m = Self.parse(parts[0], 0...59), let h = Self.parse(parts[1], 0...23), let d = Self.parse(parts[2], 1...31),
              let mo = Self.parse(parts[3], 1...12), let w = Self.parse(parts[4], 0...7) else { return nil }
        minutes = m; hours = h; days = d; months = mo
        weekdays = Set(w.map { $0 == 7 ? 0 : $0 })
        fields = parts
    }

    static func parse(_ field: String, _ range: ClosedRange<Int>) -> Set<Int>? {
        var out = Set<Int>()
        for part in field.split(separator: ",") {
            var stepPart = String(part)
            var step = 1
            if let slash = part.firstIndex(of: "/") {
                guard let s = Int(part[part.index(after: slash)...]), s > 0 else { return nil }
                step = s; stepPart = String(part[..<slash])
            }
            var lo = range.lowerBound, hi = range.upperBound
            if stepPart != "*" && stepPart != "?" {
                let ends = stepPart.split(separator: "-").map { Int($0) }
                if ends.count == 1, let a = ends[0] { lo = a; hi = part.contains("/") ? range.upperBound : a }
                else if ends.count == 2, let a = ends[0], let b = ends[1] { lo = a; hi = b }
                else { return nil }
            }
            guard range.contains(lo), range.contains(hi), lo <= hi else { return nil }
            out.formUnion(stride(from: lo, through: hi, by: step))
        }
        return out.isEmpty ? nil : out
    }

    /// Next `count` fire times strictly after `date`, evaluated in `timeZone`.
    public func nextRuns(after date: Date, count: Int = 3, timeZone: TimeZone = .gmt) -> [Date] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        guard var t = cal.date(from: cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)) else { return [] }
        var out: [Date] = []
        let dayRestricted = fields[2] != "*" && fields[2] != "?", weekdayRestricted = fields[4] != "*" && fields[4] != "?"
        var steps = 0
        while out.count < count, steps < 60 * 24 * 400 {
            t = t.addingTimeInterval(60); steps += 1
            let c = cal.dateComponents([.month, .day, .hour, .minute, .weekday], from: t)
            guard let mo = c.month, let d = c.day, let h = c.hour, let mi = c.minute, let wd = c.weekday else { continue }
            guard months.contains(mo), hours.contains(h), minutes.contains(mi) else { continue }
            let dayOK = days.contains(d), wdOK = weekdays.contains(wd - 1)
            let match = (dayRestricted && weekdayRestricted) ? (dayOK || wdOK) : (dayOK && wdOK)
            if match { out.append(t) }
        }
        return out
    }

    /// Short English description of common schedules; falls back to the raw fields.
    public func describe() -> String {
        let f = fields
        func two(_ n: String) -> String { n.count == 1 ? "0" + n : n }
        if f == ["*", "*", "*", "*", "*"] { return "Every minute" }
        if f[0].hasPrefix("*/"), Array(f[1...]) == ["*", "*", "*", "*"] { return "Every \(f[0].dropFirst(2)) minutes" }
        if f[1] == "*", f[2] == "*", f[3] == "*", f[4] == "*", Int(f[0]) != nil { return f[0] == "0" ? "Every hour" : "Every hour at :\(two(f[0]))" }
        if let m = Int(f[0]), let h = Int(f[1]) {
            let time = "\(two(String(h))):\(two(String(m)))"
            if f[2] == "*", f[3] == "*", f[4] == "*" { return "Every day at \(time)" }
            if f[2] == "*", f[3] == "*", let w = Int(f[4]) { return "Every \(Calendar(identifier: .gregorian).weekdaySymbols[w % 7]) at \(time)" }
            if f[3] == "*", f[4] == "*", let d = Int(f[2]) { return "Day \(d) of every month at \(time)" }
        }
        return f.joined(separator: " ")
    }
}

// MARK: - Export & secrets

public enum ResourceExport {
    /// YAML for "Copy YAML": the object without `metadata.managedFields`.
    public static func yaml(_ object: JSONValue) -> String {
        var o = object
        if var meta = o["metadata"]?.objectValue { meta["managedFields"] = nil; o["metadata"] = .object(meta) }
        guard let data = try? o.data(), let any = try? JSONSerialization.jsonObject(with: data),
              let text = try? Yams.dump(object: any, sortKeys: true) else { return o.jsonString(pretty: true) }
        return text
    }
}

public enum SecretDecoder {
    /// Decodes a base64 secret value to text, or nil when it is not valid UTF-8 (binary).
    public static func text(fromBase64 value: String) -> String? {
        guard let data = Data(base64Encoded: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    public static func byteCount(base64 value: String) -> Int { Data(base64Encoded: value)?.count ?? 0 }

    /// Registry hostnames in a `.dockerconfigjson` secret value (the credentials are not returned).
    public static func registries(dockerConfigBase64 value: String) -> [String] {
        guard let data = Data(base64Encoded: value), let json = try? JSONValue.parse(data) else { return [] }
        return (json["auths"]?.objectValue ?? [:]).keys.sorted()
    }
}
