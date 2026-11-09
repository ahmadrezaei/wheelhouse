import Foundation
import Yams

/// The `clusters`, `users` and `contexts` entries a writer adds to a kubeconfig. Holds no secret: a server URL, a CA certificate and an
/// `exec` plugin stanza.
public struct KubeconfigEntries: Codable, Equatable, Sendable {
    public struct NamedCluster: Codable, Equatable, Sendable {
        public struct Cluster: Codable, Equatable, Sendable {
            public var server: String
            public var certificateAuthorityData: String?
            enum CodingKeys: String, CodingKey { case server, certificateAuthorityData = "certificate-authority-data" }
            public init(server: String, certificateAuthorityData: String?) {
                self.server = server
                self.certificateAuthorityData = certificateAuthorityData
            }
        }
        public var name: String
        public var cluster: Cluster
        public init(name: String, cluster: Cluster) { self.name = name; self.cluster = cluster }
    }

    public struct NamedUser: Codable, Equatable, Sendable {
        public struct User: Codable, Equatable, Sendable {
            public struct Exec: Codable, Equatable, Sendable {
                public struct EnvVar: Codable, Equatable, Sendable {
                    public var name: String
                    public var value: String
                    public init(name: String, value: String) { self.name = name; self.value = value }
                }
                public var apiVersion: String
                public var command: String
                public var args: [String]
                public var env: [EnvVar]?
                public var installHint: String?
                public var provideClusterInfo: Bool?
                public var interactiveMode: String?
                public init(apiVersion: String, command: String, args: [String], env: [EnvVar]? = nil, installHint: String? = nil,
                            provideClusterInfo: Bool? = nil, interactiveMode: String? = nil) {
                    self.apiVersion = apiVersion
                    self.command = command
                    self.args = args
                    self.env = env
                    self.installHint = installHint
                    self.provideClusterInfo = provideClusterInfo
                    self.interactiveMode = interactiveMode
                }
            }
            public var exec: Exec
            public init(exec: Exec) { self.exec = exec }
        }
        public var name: String
        public var user: User
        public init(name: String, user: User) { self.name = name; self.user = user }
    }

    public struct NamedContext: Codable, Equatable, Sendable {
        public struct Context: Codable, Equatable, Sendable {
            public var cluster: String
            public var user: String
            public init(cluster: String, user: String) { self.cluster = cluster; self.user = user }
        }
        public var name: String
        public var context: Context
        public init(name: String, context: Context) { self.name = name; self.context = context }
    }

    public var clusters: [NamedCluster]
    public var users: [NamedUser]
    public var contexts: [NamedContext]

    public init(clusters: [NamedCluster] = [], users: [NamedUser] = [], contexts: [NamedContext] = []) {
        self.clusters = clusters
        self.users = users
        self.contexts = contexts
    }

    public var isEmpty: Bool { clusters.isEmpty && users.isEmpty && contexts.isEmpty }

    /// The exact YAML that is merged (shown before a merge into the user's file).
    public func yaml() throws -> String { try YAMLEncoder().encode(self) }
}

public enum KubeconfigMergeError: Error, Equatable, Sendable, LocalizedError {
    case notAKubeconfig(String)
    case multipleDocuments
    case duplicateName(String)
    case verification(String)

    public var errorDescription: String? {
        switch self {
        case .notAKubeconfig(let why): "This file is not a kubeconfig: \(why)"
        case .multipleDocuments: "This file has more than one YAML document, so Wheelhouse does not change it."
        case .duplicateName(let n): "This file defines \(n) more than once, so Wheelhouse does not change it."
        case .verification(let why): "The merged file did not match what was expected: \(why)"
        }
    }
}

/// Adds or replaces named `clusters`, `users` and `contexts` entries in a kubeconfig document and leaves everything else (above all
/// `current-context`) as it is. Comments are not kept, as with `kubectl config`. Operates on YAML nodes, so key order is kept and a
/// profile name or account number stays a string. YAML aliases are written out as copies (the same meaning).
public enum KubeconfigMergeEditor {
    public static let sections = ["clusters", "users", "contexts"]

    public struct Merged: Sendable, Equatable {
        public var text: String
        /// `clusters/<name>` etc.
        public var added: [String]
        public var replaced: [String]
    }

    static func parse(_ text: String?) throws -> Yams.Node {
        let source = (text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ? "apiVersion: v1\nkind: Config\n" : text ?? ""
        let docs: [Yams.Node]
        do { docs = Array(try compose_all(yaml: source)) } catch { throw KubeconfigMergeError.notAKubeconfig("it is not valid YAML") }
        guard docs.count <= 1 else { throw KubeconfigMergeError.multipleDocuments }
        guard let root = docs.first, case .mapping = root else { throw KubeconfigMergeError.notAKubeconfig("the top level is not a mapping") }
        return root
    }

    private static func isNull(_ node: Yams.Node) -> Bool {
        guard case .scalar(let s) = node else { return false }
        return ["", "~", "null", "Null", "NULL"].contains(s.string)
    }

    private static func items(_ root: Yams.Node, _ key: String) throws -> [Yams.Node] {
        guard let node = root[key], !isNull(node) else { return [] }
        guard case .sequence(let seq) = node else { throw KubeconfigMergeError.notAKubeconfig("\(key) is not a list") }
        return Array(seq)
    }

    private static func name(of node: Yams.Node) -> String? { node["name"]?.string }

    public static func merge(existing: String?, entriesYAML: String) throws -> Merged {
        var root = try parse(existing)
        let entries = try parse(entriesYAML)
        var added: [String] = [], replaced: [String] = []
        for key in sections {
            var out = try items(root, key)
            let incoming = try items(entries, key)
            let incomingNames = incoming.compactMap(name(of:))
            guard incomingNames.count == incoming.count, Set(incomingNames).count == incomingNames.count else {
                throw KubeconfigMergeError.notAKubeconfig("the entries to merge need unique names")
            }
            for n in incomingNames where out.filter({ name(of: $0) == n }).count > 1 { throw KubeconfigMergeError.duplicateName("\(key)/\(n)") }
            for node in incoming {
                guard let n = name(of: node) else { continue }
                if let i = out.firstIndex(where: { name(of: $0) == n }) { out[i] = node; replaced.append("\(key)/\(n)") } else { out.append(node); added.append("\(key)/\(n)") }
            }
            root[key] = Yams.Node.sequence(Yams.Node.Sequence(out))
        }
        let text = try serialize(node: root, width: -1, allowUnicode: true)
        return Merged(text: text, added: added, replaced: replaced)
    }

    /// Compares the written document with the one that was there: every key except the three sections (so `current-context`) is equal,
    /// every entry that was not named is equal, and every named entry equals the one merged. Throws ``KubeconfigMergeError/verification(_:)``.
    public static func verify(before: String?, after: String, entriesYAML: String) throws {
        func fail(_ why: String) -> KubeconfigMergeError { .verification(why) }
        let old: Yams.Node, new: Yams.Node, entries: Yams.Node
        do { old = try parse(before); new = try parse(after); entries = try parse(entriesYAML) } catch { throw fail("the file could not be read back") }
        guard case .mapping(let oldMap) = old, case .mapping(let newMap) = new else { throw fail("not a mapping") }
        let oldKeys = oldMap.compactMap { $0.key.string }.filter { !sections.contains($0) }
        let newKeys = newMap.compactMap { $0.key.string }.filter { !sections.contains($0) }
        guard Set(oldKeys) == Set(newKeys) else { throw fail("top-level keys changed") }
        for key in oldKeys where old[key] != new[key] { throw fail(key == "current-context" ? "current-context changed" : "\(key) changed") }
        for key in sections {
            let before = try items(old, key), after = try items(new, key), incoming = try items(entries, key)
            let names = Set(incoming.compactMap(name(of:)))
            let untouchedBefore = before.filter { !names.contains(name(of: $0) ?? "") }
            let untouchedAfter = after.filter { !names.contains(name(of: $0) ?? "") }
            guard untouchedBefore == untouchedAfter else { throw fail("an existing entry in \(key) changed") }
            for node in incoming {
                let matches = after.filter { name(of: $0) == name(of: node) }
                guard matches.count == 1, matches[0] == node else { throw fail("\(key) entry \(name(of: node) ?? "?") is not as merged") }
            }
        }
    }
}
