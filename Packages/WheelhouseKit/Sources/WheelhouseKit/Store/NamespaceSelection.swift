import Foundation

/// Which namespaces a screen shows: everything, or a non-empty set of names.
///
/// Persisted as one string per cluster: `"*"` for All, the bare name for one namespace (the format every earlier version wrote)
/// and a comma-joined, sorted list for several. Namespace names are DNS labels, so neither `*` nor `,` can occur in one.
public enum NamespaceSelection: Hashable, Sendable {
    case all
    /// Always at least one name, sorted and without duplicates; build it through ``init(names:)``.
    case namespaces([String])

    /// Most namespaces a selection may hold: every one is a live watch, and the transport allows a handful of long requests per host.
    public static let limit = 6
    static let allToken = "*"

    /// Normalises: trims, drops empty and duplicate names, sorts. No names means All.
    public init(names: some Sequence<String>) {
        let cleaned = Set(names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        self = cleaned.isEmpty ? .all : .namespaces(cleaned.sorted())
    }

    public init(_ name: String?) { self.init(names: name.map { [$0] } ?? []) }

    /// Reads the persisted form. `*`, an empty string and whitespace are All.
    public init(encoded: String) {
        self = encoded == Self.allToken ? .all : Self(names: encoded.split(separator: ",").map(String.init))
    }

    public var encoded: String {
        switch self {
        case .all: Self.allToken
        case .namespaces(let names): names.joined(separator: ",")
        }
    }

    /// The selected names; empty for All.
    public var names: [String] {
        if case .namespaces(let names) = self { names } else { [] }
    }

    public var isAll: Bool { self == .all }

    /// The name when exactly one namespace is selected, else nil.
    public var single: String? {
        if case .namespaces(let names) = self, names.count == 1 { names[0] } else { nil }
    }

    public func contains(_ name: String) -> Bool { names.contains(name) }

    /// Adds or removes one name; removing the last one gives All. Adding beyond ``limit`` leaves the selection unchanged.
    public func toggling(_ name: String) -> NamespaceSelection {
        var set = Set(names)
        if set.remove(name) == nil {
            guard set.count < Self.limit else { return self }
            set.insert(name)
        }
        return Self(names: set)
    }

    /// Chip and button text: `All namespaces`, `payments`, `payments, web`, or `3 namespaces` from three names up.
    public var label: String {
        switch self {
        case .all: "All namespaces"
        case .namespaces(let names): names.count <= 2 ? names.joined(separator: ", ") : "\(names.count) namespaces"
        }
    }

    /// Every selected name, for a tooltip.
    public var detail: String { isAll ? "All namespaces" : names.joined(separator: ", ") }
}
