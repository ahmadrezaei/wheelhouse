import Foundation

/// A Rigging pack (ARCHITECTURE-MAC section 11): declarative data that adds views, commands and health rules for custom resources.
/// A pack is parsed from `rigging.yaml`, validated against the bundled JSON Schema and checked again by ``RiggingPackValidator``.
/// It holds no code. Nothing in it is evaluated except the closed sets in ``JSONPathSubset`` and ``RiggingTemplate``.
public struct RiggingPack: Codable, Hashable, Sendable, Identifiable {
    public static let apiVersion = "rigging.wheelhouse.app/v1"

    public struct Metadata: Codable, Hashable, Sendable {
        public var name: String
        public var version: String
        public var description: String?
        public var author: String?
        public var homepage: String?
    }

    /// A kind, by API group and Kind. The core group is "".
    public struct KindMatch: Codable, Hashable, Sendable {
        public var group: String
        public var kind: String
        public init(group: String, kind: String) { self.group = group; self.kind = kind }
    }

    public struct Column: Codable, Hashable, Sendable {
        public enum Format: String, Codable, Hashable, Sendable { case text, age, number, bool }
        public var name: String
        public var path: String
        public var format: Format?
    }

    public struct Field: Codable, Hashable, Sendable {
        public var name: String
        public var path: String
    }

    public enum Tone: String, Codable, Hashable, Sendable { case neutral, healthy, warning, critical }

    /// What a status rule or health rule checks. Either a named condition (`status.conditions[type==X].status == status`) or a path.
    public struct Condition: Codable, Hashable, Sendable {
        public var condition: String?
        public var status: String?
        public var path: String?
        public var exists: Bool?
        public var equals: String?
        public var oneOf: [String]?
        /// How long the condition has had this status (`30m`, `1h`, `2d`), from its `lastTransitionTime`. Health rules only.
        public var duration: String?

        enum CodingKeys: String, CodingKey { case condition, status, path, exists, equals, oneOf = "in", duration = "for" }
    }

    public struct StatusRule: Codable, Hashable, Sendable {
        public var when: Condition
        public var tone: Tone
        public var label: String?
    }

    public struct Related: Codable, Hashable, Sendable {
        public var kind: String
        public var group: String?
        public var nameFrom: String
        public var namespaceFrom: String?
        public var label: String
    }

    public struct ViewSpec: Codable, Hashable, Sendable, Identifiable {
        public var id: String?
        public var title: String?
        public var symbol: String?
        public var match: KindMatch
        public var columns: [Column]?
        public var fields: [Field]?
        public var status: [StatusRule]?
        public var related: [Related]?

        /// The id a `riggingView` destination carries: the declared one, or the lowercased Kind.
        public var viewID: String { id ?? match.kind.lowercased() }
    }

    public struct PortForward: Codable, Hashable, Sendable {
        public var service: String?
        public var pod: String?
        public var namespace: String
        public var port: Int
        /// Where to open the browser once the forward is up; `{{localPort}}` is the only variable.
        public var open: String?
    }

    public struct Command: Codable, Hashable, Sendable, Identifiable {
        public var title: String
        public var `for`: KindMatch?
        public var terminal: String?
        public var portForward: PortForward?
        public var id: String { title + "|" + (`for`.map { "\($0.group)/\($0.kind)" } ?? "") }
    }

    public struct HealthRule: Codable, Hashable, Sendable, Identifiable {
        public var `for`: KindMatch
        public var when: Condition
        public enum Tone: String, Codable, Hashable, Sendable { case warning, critical }
        public var tone: Tone
        public var message: String
        public var id: String { "\(`for`.group)/\(`for`.kind)|\(message)" }
    }

    /// Orders the kinds of one API group under Custom Resources and may rename the group's row.
    public struct SidebarGroup: Codable, Hashable, Sendable {
        public var apiGroup: String
        public var title: String?
        public var kinds: [String]?
    }

    public var apiVersion: String
    public var kind: String
    public var metadata: Metadata
    public var sidebar: [SidebarGroup]?
    public var views: [ViewSpec]?
    public var commands: [Command]?
    public var healthRules: [HealthRule]?

    public var id: String { metadata.name }
    public var allViews: [ViewSpec] { views ?? [] }
    public var allCommands: [Command] { commands ?? [] }
    public var allHealthRules: [HealthRule] { healthRules ?? [] }
    public var allSidebar: [SidebarGroup] { sidebar ?? [] }

    /// The fields a template for objects of `kind` may use: those the pack's views declare for it.
    public func fields(for kind: KindMatch) -> [Field] {
        allViews.filter { $0.match == kind }.flatMap { $0.fields ?? [] }
    }

    public func view(id: String) -> ViewSpec? { allViews.first { $0.viewID == id } }

    /// Commands that apply to objects of `kind`, then those that apply anywhere (no `for`).
    public func commands(for kind: KindMatch) -> [Command] { allCommands.filter { $0.for == kind } }
    public var globalCommands: [Command] { allCommands.filter { $0.for == nil } }
}

/// A built-in or installed pack and where it came from.
public struct RiggingPackSource: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable { case builtIn, folder, git }
    public var kind: Kind
    /// The folder path or the git URL.
    public var location: String?
    /// The pinned commit of a git pack.
    public var commit: String?
    /// The ref asked for when the pack was added (a branch, tag or commit), for the manual update.
    public var ref: String?

    public init(kind: Kind, location: String? = nil, commit: String? = nil, ref: String? = nil) {
        self.kind = kind
        self.location = location
        self.commit = commit
        self.ref = ref
    }

    public static let builtIn = RiggingPackSource(kind: .builtIn)

    public var summary: String {
        switch kind {
        case .builtIn: "Built in"
        case .folder: location.map { "Folder: \($0)" } ?? "Folder"
        case .git: "\(location ?? "git") @ \(commit.map { String($0.prefix(12)) } ?? "unknown")"
        }
    }
}
