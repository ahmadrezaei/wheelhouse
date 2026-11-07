import Foundation

/// One object of a release manifest (or of a hook).
public struct HelmManifestObject: Sendable, Hashable, Identifiable {
    public var apiVersion: String
    public var kind: String
    public var name: String
    /// nil when the manifest does not set one (the release namespace applies to namespaced kinds).
    public var namespace: String?
    /// The `# Source:` template path Helm writes above each document.
    public var source: String?
    public var yaml: String
    public var value: JSONValue

    public var id: String { "\(kind)/\(namespace ?? "-")/\(name)" }
}

public enum HelmManifest {
    /// Splits a rendered manifest into objects. `kind: List` documents are flattened; empty documents are skipped.
    public static func objects(in manifest: String) -> [HelmManifestObject] {
        var result: [HelmManifestObject] = []
        for document in YAMLCodec.parseDocuments(manifest) {
            guard let value = document.value, document.diagnostic == nil else { continue }
            let source = document.text.split(separator: "\n").first { $0.hasPrefix("# Source:") }
                .map { String($0.dropFirst("# Source:".count)).trimmingCharacters(in: .whitespaces) }
            if value["kind"]?.stringValue == "List", let items = value["items"]?.arrayValue {
                for item in items { if let o = object(item, yaml: YAMLCodec.dump(item), source: source) { result.append(o) } }
            } else if let o = object(value, yaml: document.text, source: source) {
                result.append(o)
            }
        }
        return result
    }

    private static func object(_ value: JSONValue, yaml: String, source: String?) -> HelmManifestObject? {
        guard let kind = value["kind"]?.stringValue, let apiVersion = value["apiVersion"]?.stringValue,
              let name = value.value(at: "metadata.name")?.stringValue ?? value.value(at: "metadata.generateName")?.stringValue else { return nil }
        return HelmManifestObject(apiVersion: apiVersion, kind: kind, name: name, namespace: value.value(at: "metadata.namespace")?.stringValue,
                                  source: source, yaml: yaml, value: value)
    }

    /// The REST kind for a manifest object: built-in table, then discovery, then a guess from the kind name.
    public static func resourceKind(for object: HelmManifestObject, discovery: DiscoveryInfo?) -> ResourceKind {
        let parts = object.apiVersion.split(separator: "/", maxSplits: 1).map(String.init)
        let group = parts.count == 2 ? parts[0] : ""
        let version = parts.count == 2 ? parts[1] : object.apiVersion
        if let known = ResourceKind.builtIn.first(where: { $0.kind == object.kind && $0.group == group }) {
            var kind = known
            kind.version = version
            return kind
        }
        if let found = discovery?.topLevel.first(where: { $0.kind == object.kind && ($0.group ?? "") == group }) {
            return .custom(group: group, version: found.version ?? version, kind: object.kind, plural: found.name, namespaced: found.namespaced)
        }
        return .custom(group: group, version: version, kind: object.kind, plural: pluralGuess(object.kind), namespaced: true)
    }

    static func pluralGuess(_ kind: String) -> String {
        let lower = kind.lowercased()
        if lower.hasSuffix("s") || lower.hasSuffix("x") || lower.hasSuffix("ch") { return lower + "es" }
        if lower.hasSuffix("y") { return String(lower.dropLast()) + "ies" }
        return lower + "s"
    }
}

/// Drift: how the live objects differ from what the release manifest says (computed lazily, one GET per object, 4 in flight).
public enum HelmDrift {
    public enum State: Sendable, Hashable {
        case inSync
        /// Dotted paths whose live value differs from the manifest.
        case drifted(paths: [String])
        case missing
        case unreadable(String)

        public var isDrift: Bool {
            switch self {
            case .drifted, .missing: true
            default: false
            }
        }
    }

    public struct ObjectDrift: Sendable, Hashable, Identifiable {
        public var object: HelmManifestObject
        public var kind: ResourceKind
        public var state: State
        /// Normalised manifest YAML and the live YAML cut down to the keys the manifest sets, for a `LineDiff`. Secret values are hidden.
        public var desiredYAML: String
        public var liveYAML: String
        /// "2/3 ready" and similar for workloads.
        public var liveSummary: String?
        public var id: String { object.id }
    }

    public struct Report: Sendable {
        public var objects: [ObjectDrift]
        public var hasDrift: Bool { objects.contains { $0.state.isDrift } }
        public var driftCount: Int { objects.filter { $0.state.isDrift }.count }
    }

    public static let maxInFlight = 4

    public static func check(manifest: String, releaseNamespace: String, client: any KubeClientProtocol, discovery: DiscoveryInfo?) async -> Report {
        let objects = HelmManifest.objects(in: manifest)
        var results: [Int: ObjectDrift] = [:]
        await withTaskGroup(of: (Int, ObjectDrift).self) { group in
            var next = 0
            func launch() {
                guard next < objects.count else { return }
                let index = next
                next += 1
                let object = objects[index]
                group.addTask { (index, await checkOne(object, releaseNamespace: releaseNamespace, client: client, discovery: discovery)) }
            }
            for _ in 0..<min(maxInFlight, objects.count) { launch() }
            while let (index, drift) = await group.next() {
                results[index] = drift
                launch()
            }
        }
        return Report(objects: objects.indices.compactMap { results[$0] })
    }

    static func checkOne(_ object: HelmManifestObject, releaseNamespace: String, client: any KubeClientProtocol, discovery: DiscoveryInfo?) async -> ObjectDrift {
        let kind = HelmManifest.resourceKind(for: object, discovery: discovery)
        let namespace = kind.namespaced ? (object.namespace ?? releaseNamespace) : nil
        let desired = normalise(object.value, kind: kind.kind)
        let desiredYAML = YAMLCodec.dump(hideSecrets(desired, kind: kind.kind))
        do {
            let live = try await client.getRaw(kind, name: object.name, namespace: namespace)
            let paths = differences(desired: desired, live: live)
            let projected = project(live, onto: desired)
            return ObjectDrift(object: object, kind: kind, state: paths.isEmpty ? .inSync : .drifted(paths: paths), desiredYAML: desiredYAML,
                               liveYAML: YAMLCodec.dump(hideSecrets(projected, kind: kind.kind)), liveSummary: summary(of: live, kind: kind))
        } catch KubeError.notFound {
            return ObjectDrift(object: object, kind: kind, state: .missing, desiredYAML: desiredYAML, liveYAML: "", liveSummary: nil)
        } catch {
            return ObjectDrift(object: object, kind: kind, state: .unreadable(Self.describe(error)), desiredYAML: desiredYAML, liveYAML: "", liveSummary: nil)
        }
    }

    private static func describe(_ error: Error) -> String {
        if case KubeError.forbidden = error { return "Not permitted to read this object" }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    // MARK: Normalisation and comparison

    /// Drops what the server owns: status, identity and bookkeeping metadata, and the last-applied annotation. For Secrets,
    /// `stringData` is folded into `data` the way the API server does.
    static func normalise(_ value: JSONValue, kind: String) -> JSONValue {
        var v = value
        v["status"] = nil
        guard case .object(var meta)? = v["metadata"] else { return v }
        for key in ["managedFields", "resourceVersion", "uid", "creationTimestamp", "generation", "selfLink", "deletionTimestamp"] { meta[key] = nil }
        if case .object(var annotations)? = meta["annotations"] {
            annotations["kubectl.kubernetes.io/last-applied-configuration"] = nil
            meta["annotations"] = annotations.isEmpty ? nil : .object(annotations)
        }
        v["metadata"] = .object(meta)
        if kind == "Secret", case .object(let strings)? = v["stringData"] {
            var data = v["data"]?.objectValue ?? [:]
            for (k, s) in strings { if let s = s.stringValue { data[k] = .string(Data(s.utf8).base64EncodedString()) } }
            v["data"] = .object(data)
            v["stringData"] = nil
        }
        return v
    }

    /// Paths where `desired` sets a value that `live` does not have. Fields the server added (defaults) are ignored by construction.
    static func differences(desired: JSONValue, live: JSONValue) -> [String] {
        var paths: [String] = []
        compare(desired, live, path: "", into: &paths)
        return paths
    }

    private static func compare(_ desired: JSONValue, _ live: JSONValue?, path: String, into paths: inout [String]) {
        func join(_ key: String) -> String { path.isEmpty ? key : path + "." + key }
        switch desired {
        case .object(let d):
            guard case .object(let l)? = live else {
                if !d.isEmpty { paths.append(path.isEmpty ? "(root)" : path) }
                return
            }
            for (key, value) in d where key != "status" { compare(value, l[key], path: join(key), into: &paths) }
        case .array(let d):
            if d.isEmpty { return }
            guard case .array(let l)? = live else { paths.append(path); return }
            if d.allSatisfy({ $0["name"]?.stringValue != nil }) && l.allSatisfy({ $0["name"]?.stringValue != nil }) {
                for item in d {
                    let name = item["name"]?.stringValue ?? ""
                    guard let match = l.first(where: { $0["name"]?.stringValue == name }) else { paths.append("\(path)[\(name)]"); continue }
                    compare(item, match, path: "\(path)[\(name)]", into: &paths)
                }
            } else if d.count != l.count {
                paths.append(path)
            } else {
                for (i, item) in d.enumerated() { compare(item, l[i], path: "\(path)[\(i)]", into: &paths) }
            }
        case .null:
            return                                  // `creationTimestamp: null` and friends: absent on the server is the same
        default:
            if !scalarEqual(desired, live) { paths.append(path) }
        }
    }

    private static func scalarEqual(_ a: JSONValue, _ b: JSONValue?) -> Bool {
        guard let b else { return false }
        switch (a, b) {
        case (.int, .double), (.double, .int), (.double, .double): return a.doubleValue == b.doubleValue
        case (.string(let x), .int), (.string(let x), .double): return x == b.doubleValue.map { $0 == $0.rounded() ? String(Int($0)) : String($0) }
        case (.int, .string(let y)), (.double, .string(let y)): return y == a.doubleValue.map { $0 == $0.rounded() ? String(Int($0)) : String($0) }
        default: return a == b
        }
    }

    /// `live` cut down to the structure `desired` sets, so the two texts differ only where the release's intent is not met.
    static func project(_ live: JSONValue, onto desired: JSONValue) -> JSONValue {
        switch (desired, live) {
        case (.object(let d), .object(let l)):
            var out: [String: JSONValue] = [:]
            for key in d.keys { if let value = l[key] { out[key] = project(value, onto: d[key] ?? .null) } }
            return .object(out)
        case (.array(let d), .array(let l)):
            if d.allSatisfy({ $0["name"]?.stringValue != nil }) {
                return .array(d.compactMap { item in
                    l.first { $0["name"]?.stringValue == item["name"]?.stringValue }.map { project($0, onto: item) }
                })
            }
            return .array(zip(d, l).map { project($1, onto: $0) } + l.dropFirst(d.count))
        default:
            return live
        }
    }

    private static func hideSecrets(_ value: JSONValue, kind: String) -> JSONValue {
        guard kind == "Secret", case .object(let data)? = value["data"] else { return value }
        var v = value
        v["data"] = .object(data.mapValues { _ in .string("<hidden>") })
        return v
    }

    private static func summary(of live: JSONValue, kind: ResourceKind) -> String? {
        switch kind.kind {
        case "Deployment", "StatefulSet", "ReplicaSet":
            let want = live.value(at: "spec.replicas")?.intValue ?? 1
            return "\(live.value(at: "status.readyReplicas")?.intValue ?? 0)/\(want) ready"
        case "DaemonSet":
            return "\(live.value(at: "status.numberReady")?.intValue ?? 0)/\(live.value(at: "status.desiredNumberScheduled")?.intValue ?? 0) ready"
        case "Job":
            return live.value(at: "status.succeeded")?.intValue.map { "\($0) succeeded" }
        case "Pod":
            return live.value(at: "status.phase")?.stringValue
        default:
            return nil
        }
    }
}
