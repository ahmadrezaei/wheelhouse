import Foundation

/// Turns the name a model or a manifest uses (`Deployment`, `deployments`, `deployment.apps`, `apps/v1` + `Deployment`) into a
/// ``ResourceKind``. Pure: discovery is passed in, so custom resources work without a client.
public enum KindResolver {
    private static let extraBuiltIn: [ResourceKind] = [.podDisruptionBudget, .horizontalPodAutoscaler]

    public static func resolve(_ name: String, discovery: DiscoveryInfo? = nil) -> ResourceKind? {
        let lowered = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !lowered.isEmpty else { return nil }
        // `plural.group` form.
        var base = lowered
        var group: String?
        if let dot = lowered.firstIndex(of: "."), !lowered.hasPrefix(".") {
            base = String(lowered[..<dot])
            group = String(lowered[lowered.index(after: dot)...])
        }
        let all = ResourceKind.builtIn + extraBuiltIn
        if let hit = all.first(where: { matches($0, base: base, group: group) }) { return hit }
        if let discovery {
            for r in discovery.topLevel where matches(name: r.name, kind: r.kind, singular: r.singularName, short: r.shortNames ?? [], base: base) {
                if let group, (r.group ?? "") != group { continue }
                if let g = r.group, let v = r.version, !g.isEmpty, pathSafe(g, v, r.name) {
                    return .custom(group: g, version: v, kind: r.kind, plural: r.name, namespaced: r.namespaced)
                }
            }
        }
        return nil
    }

    /// For manifests: matches `kind` within an `apiVersion`.
    public static func resolve(apiVersion: String, kind: String, discovery: DiscoveryInfo? = nil) -> ResourceKind? {
        let parts = apiVersion.split(separator: "/", maxSplits: 1).map(String.init)
        let group = parts.count == 2 ? parts[0] : ""
        let version = parts.last ?? ""
        if let hit = (ResourceKind.builtIn + extraBuiltIn).first(where: { $0.kind == kind && $0.group == group }) { return hit }
        if let r = discovery?.topLevel.first(where: { $0.kind == kind && ($0.group ?? "") == group }), let v = r.version, pathSafe(group, v, r.name) {
            return .custom(group: group, version: v, kind: r.kind, plural: r.name, namespaced: r.namespaced)
        }
        return nil
    }

    /// Group, version and plural come from the cluster and end up in a request path; only DNS-like text may.
    private static func pathSafe(_ parts: String...) -> Bool {
        parts.allSatisfy { !$0.isEmpty && $0.count <= 253 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") } }
    }

    private static func matches(_ kind: ResourceKind, base: String, group: String?) -> Bool {
        if let group, kind.group != group { return false }
        return kind.kind.lowercased() == base || kind.plural == base || kind.displayName.lowercased() == base
    }

    private static func matches(name: String, kind: String, singular: String?, short: [String], base: String) -> Bool {
        name == base || kind.lowercased() == base || singular == base || short.contains(base)
    }
}
