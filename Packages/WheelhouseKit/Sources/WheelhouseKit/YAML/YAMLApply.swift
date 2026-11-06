import Foundation

/// A validation problem reported by the server (or by local checks), optionally mapped to a line of the edited text.
public struct YAMLIssue: Identifiable, Hashable, Sendable {
    public var id: String { "\(field ?? "")|\(message)" }
    public var field: String?
    public var message: String
    public var reason: String?
    public var line: Int?
    public init(field: String? = nil, message: String, reason: String? = nil, line: Int? = nil) {
        self.field = field
        self.message = message
        self.reason = reason
        self.line = line
    }
}

public enum YAMLIssues {
    /// Turns an API error into inline issues. `text` + `lineOffset` map field paths to lines of the editor.
    public static func issues(from error: KubeError, text: String? = nil, lineOffset: Int = 0) -> [YAMLIssue] {
        func line(_ field: String?) -> Int? {
            guard let field, !field.isEmpty, let text, let l = YAMLCodec.line(forPath: field, in: text) else { return nil }
            return l + lineOffset
        }
        switch error {
        case .invalid(let message, let causes):
            let mapped = causes.compactMap { c -> YAMLIssue? in
                guard let m = c.message ?? c.reason else { return nil }
                // Server messages repeat the path ("spec.replicas: Invalid value: …"); keep the field separately.
                return YAMLIssue(field: c.field, message: cleaned(m, field: c.field), reason: c.reason, line: line(c.field))
            }
            return mapped.isEmpty ? [YAMLIssue(message: message)] : mapped
        case .forbidden(_, _, _, let message): return [YAMLIssue(message: message)]
        case .conflict(let m): return [YAMLIssue(message: m ?? error.summary, reason: "Conflict")]
        default: return [YAMLIssue(message: error.summary)]
        }
    }

    private static func cleaned(_ message: String, field: String?) -> String {
        guard let field, message.hasPrefix(field + ": ") else { return message }
        return String(message.dropFirst(field.count + 2))
    }
}

/// A manifest document resolved to an API kind and ready to send.
public struct PreparedManifest: Identifiable, Sendable {
    public var id: Int { index }
    public var index: Int
    public var startLine: Int
    public var kind: ResourceKind
    public var name: String
    public var namespace: String?
    public var namespaceDefaulted: Bool
    public var body: JSONValue
    public var text: String
    public var title: String { "\(kind.kind)/\(name)" }
}

public enum ManifestPreparer {
    /// Resolves `apiVersion`/`kind` to a ``ResourceKind`` (built-ins first, then discovery for custom resources).
    public static func resolveKind(apiVersion: String, kind: String, discovery: DiscoveryInfo?) -> ResourceKind? {
        let parts = apiVersion.split(separator: "/", maxSplits: 1).map(String.init)
        let group = parts.count == 2 ? parts[0] : ""
        let version = parts.last ?? apiVersion
        let all = ResourceKind.builtIn + [.podDisruptionBudget, .horizontalPodAutoscaler]
        if var builtIn = all.first(where: { $0.kind == kind && $0.group == group }) {
            builtIn.version = version
            return builtIn
        }
        if let r = discovery?.topLevel.first(where: { $0.kind == kind && ($0.group ?? "") == group }) {
            return .custom(group: group, version: version, kind: kind, plural: r.name, namespaced: r.namespaced)
        }
        return nil
    }

    public enum Outcome: Sendable {
        case ready(PreparedManifest)
        case invalid(YAMLDocument, YAMLIssue)
    }

    public static func prepare(_ documents: [YAMLDocument], defaultNamespace: String?, discovery: DiscoveryInfo?) -> [Outcome] {
        documents.map { doc in
            if let d = doc.diagnostic { return .invalid(doc, YAMLIssue(message: d.message, line: d.line)) }
            guard var value = doc.value, case .object = value else { return .invalid(doc, YAMLIssue(message: "Document is not a mapping", line: doc.startLine)) }
            guard let apiVersion = doc.apiVersion else { return .invalid(doc, YAMLIssue(field: "apiVersion", message: "apiVersion is required", line: doc.startLine)) }
            guard let kindName = doc.kind else { return .invalid(doc, YAMLIssue(field: "kind", message: "kind is required", line: doc.startLine)) }
            guard let kind = resolveKind(apiVersion: apiVersion, kind: kindName, discovery: discovery) else {
                return .invalid(doc, YAMLIssue(field: "kind", message: "The cluster doesn’t serve \(kindName) (\(apiVersion))", line: YAMLCodec.line(forPath: "kind", in: doc.text).map { $0 + doc.startLine - 1 } ?? doc.startLine))
            }
            guard let name = doc.name, !name.isEmpty else {
                return .invalid(doc, YAMLIssue(field: "metadata.name", message: "metadata.name is required", line: YAMLCodec.line(forPath: "metadata", in: doc.text).map { $0 + doc.startLine - 1 } ?? doc.startLine))
            }
            var namespace = doc.namespace
            var defaulted = false
            if kind.namespaced {
                if namespace == nil, let d = defaultNamespace {
                    value.setValue(.string(d), at: "metadata.namespace")
                    namespace = d
                    defaulted = true
                }
            } else {
                namespace = nil
            }
            return .ready(PreparedManifest(index: doc.index, startLine: doc.startLine, kind: kind, name: name, namespace: namespace, namespaceDefaulted: defaulted, body: value, text: doc.text))
        }
    }
}

public enum DocumentResult: Sendable, Equatable {
    case pending
    case working
    case valid(String)       // dry-run ok: will create
    case willUpdate(String)  // already exists: will be applied
    case invalid([YAMLIssue])
    case created
    case updated
    case failed([YAMLIssue])

    public var isOK: Bool {
        switch self {
        case .valid, .willUpdate, .created, .updated: true
        default: false
        }
    }
    public var isDone: Bool { self == .created || self == .updated }
}

/// Dry-runs and commits manifests: create, falling back to server-side apply when the object already exists.
public enum ManifestApplier {
    static func alreadyExists(_ e: KubeError) -> Bool {
        if case .conflict(let m) = e { return (m ?? "").contains("already exists") }
        return false
    }

    public static func dryRun(_ m: PreparedManifest, client: any KubeClientProtocol) async -> DocumentResult {
        do {
            _ = try await client.create(m.kind, namespace: m.namespace, body: m.body, options: MutationOptions(dryRun: true))
            return .valid("Will create")
        } catch let e as KubeError {
            if alreadyExists(e) {
                do {
                    _ = try await client.patch(m.kind, name: m.name, namespace: m.namespace, patch: .apply(m.body), options: MutationOptions(dryRun: true))
                    return .willUpdate("Exists · will be updated (server-side apply)")
                } catch let e2 as KubeError {
                    return .invalid(YAMLIssues.issues(from: e2, text: m.text, lineOffset: m.startLine - 1))
                } catch { return .invalid([YAMLIssue(message: error.localizedDescription)]) }
            }
            return .invalid(YAMLIssues.issues(from: e, text: m.text, lineOffset: m.startLine - 1))
        } catch {
            return .invalid([YAMLIssue(message: error.localizedDescription)])
        }
    }

    public static func commit(_ m: PreparedManifest, client: any KubeClientProtocol) async -> DocumentResult {
        do {
            _ = try await client.create(m.kind, namespace: m.namespace, body: m.body, options: MutationOptions())
            return .created
        } catch let e as KubeError {
            if alreadyExists(e) {
                do {
                    _ = try await client.patch(m.kind, name: m.name, namespace: m.namespace, patch: .apply(m.body), options: MutationOptions())
                    return .updated
                } catch let e2 as KubeError {
                    return .failed(YAMLIssues.issues(from: e2, text: m.text, lineOffset: m.startLine - 1))
                } catch { return .failed([YAMLIssue(message: error.localizedDescription)]) }
            }
            return .failed(YAMLIssues.issues(from: e, text: m.text, lineOffset: m.startLine - 1))
        } catch {
            return .failed([YAMLIssue(message: error.localizedDescription)])
        }
    }
}
