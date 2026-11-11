#if os(macOS)
import Foundation

/// What a create (POST) names in its body.
public enum CreatedName: Equatable, Sendable {
    case name(String)
    /// `metadata.generateName` when there is no `metadata.name` (the API server then appends a random suffix).
    case generateName(String)
}

/// Reads the name a Helm create asks for (ARCHITECTURE-MAC section 5.2, "Helm object grant"). Strict: anything ambiguous is nil, which
/// the grant treats as "not covered".
public enum GrantBody {
    /// Bodies of a create under a Helm grant are buffered up to 3 MB (the API server's own default request limit).
    public static let maxCreateBody = 3 * 1024 * 1024

    /// `pathNamespace` is the namespace of the request path; a body that names another one is refused (the API server would too, but
    /// the grant should not depend on that).
    public static func createdName(body: Data?, headers: [HTTPRequestHead.Header], pathNamespace: String?) -> CreatedName? {
        guard let body, !body.isEmpty, body.count <= maxCreateBody else { return nil }
        if headers.contains(where: { $0.name.lowercased() == "content-encoding" }) { return nil }
        guard let type = headers.first(where: { $0.name.lowercased() == "content-type" })?.value else { return nil }
        let media = type.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard media == "application/json", case .object(let root)? = StrictJSON.parse(body) else { return nil }
        guard case .present(.object(let meta)) = member("metadata", in: root) else { return nil }
        let nameMember = member("name", in: meta), generateMember = member("generateName", in: meta), namespaceMember = member("namespace", in: meta)
        if case .ambiguous = nameMember { return nil }
        if case .ambiguous = generateMember { return nil }
        if case .ambiguous = namespaceMember { return nil }
        if let pathNamespace, case .present(let value) = namespaceMember {
            guard case .string(let ns) = value, ns == pathNamespace || ns.isEmpty else { return nil }
        }
        if case .present(let value) = nameMember {
            guard case .string(let name) = value else { return nil }
            if !name.isEmpty { return .name(name) }
        }
        if case .present(let value) = generateMember {
            guard case .string(let prefix) = value, !prefix.isEmpty else { return nil }
            return .generateName(prefix)
        }
        return nil
    }

    private enum Member {
        case absent
        case present(StrictJSON.Value)
        /// A duplicate key, or a twin that differs only in case (Go's decoder could read either).
        case ambiguous
    }

    private static func member(_ key: String, in members: [(key: String, value: StrictJSON.Value)]) -> Member {
        let twins = members.filter { RequestClassifier.fold($0.key) == RequestClassifier.fold(key) }
        if twins.isEmpty { return .absent }
        guard twins.count == 1, twins[0].key == key else { return .ambiguous }
        return .present(twins[0].value)
    }
}
#endif
