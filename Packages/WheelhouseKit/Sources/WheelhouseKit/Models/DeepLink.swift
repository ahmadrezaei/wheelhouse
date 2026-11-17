import Foundation

/// Kubernetes name validation used for anything that arrives from outside the app (deep links, notifications).
public enum KubeNames {
    /// DNS-1123 label: lowercase alphanumerics and `-`, 1-63 chars, starting and ending alphanumeric (namespaces, containers).
    public static func isDNSLabel(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 63 else { return false }
        return matches(s, allowed: { $0 == "-" || isLowerAlnum($0) })
    }

    /// DNS-1123 subdomain: dot-separated labels, up to 253 chars. RBAC objects may also contain `:` (e.g. `system:node`).
    public static func isObjectName(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 253 else { return false }
        return matches(s, allowed: { $0 == "-" || $0 == "." || $0 == ":" || isLowerAlnum($0) })
    }

    private static func isLowerAlnum(_ c: Character) -> Bool { c.isASCII && (c.isNumber || (c.isLetter && c.isLowercase)) }

    private static func matches(_ s: String, allowed: (Character) -> Bool) -> Bool {
        guard let first = s.first, let last = s.last, isLowerAlnum(first), isLowerAlnum(last) else { return false }
        return s.allSatisfy(allowed)
    }
}

/// `wheelhouse://cluster/{id}[/ns/{ns}][/{kind}/{name}][?view=logs|yaml&container=…&previous=1]`
///
/// External URLs can only open read-only views. `view=shell` is deliberately NOT supported: a link must never start an exec session.
public struct DeepLink: Equatable, Sendable {
    public var clusterID: ClusterID
    public var namespace: String?
    public var kind: ResourceKind?
    public var name: String?
    public var view: String?
    public var container: String?
    public var previous = false

    /// The scheme every build understands (iOS and the GitHub edition emit it too).
    public static let baseScheme = "wheelhouse"

    /// The scheme this build emits: the Info.plist key `WHURLScheme` (the App Store edition sets `wheelhouse-mas` so it never competes
    /// with the GitHub edition for `wheelhouse://`), else ``baseScheme``. Read from the main bundle, so a widget extension needs the
    /// key in its own Info.plist.
    public static let scheme = resolveScheme(Bundle.main.object(forInfoDictionaryKey: "WHURLScheme"))

    /// A configured value is used only when it is a plain lowercase URL scheme; anything else (missing, empty, an unexpanded
    /// `$(VARIABLE)`) falls back to ``baseScheme``.
    static func resolveScheme(_ value: Any?) -> String {
        guard let value = value as? String, let first = value.first, first.isASCII, first.isLetter,
              value.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }) else { return baseScheme }
        return value
    }

    /// Whether a URL scheme is one this build parses: the base scheme or its own.
    public static func accepts(_ urlScheme: String?) -> Bool { accepts(urlScheme, configured: scheme) }
    static func accepts(_ urlScheme: String?, configured: String) -> Bool { urlScheme == baseScheme || urlScheme == configured }

    /// `<scheme>://import`: opens the kubeconfig import screen (posted by the Share extension's notification). Carries no
    /// data: the kubeconfig itself travels through ``PendingKubeconfigStore``.
    public static let importURL = URL(string: "\(scheme)://import")!
    public static func isImport(_ url: URL) -> Bool { isImport(url, configured: scheme) }
    static func isImport(_ url: URL, configured: String) -> Bool {
        accepts(url.scheme, configured: configured) && url.host() == "import" && url.pathComponents.filter { $0 != "/" }.isEmpty
    }
    /// Views an external URL may request.
    public static let allowedViews: Set<String> = ["logs", "yaml"]

    public init?(url: URL) { self.init(url: url, configured: Self.scheme) }

    init?(url: URL, configured: String) {
        guard Self.accepts(url.scheme, configured: configured), url.host() == "cluster" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let id = parts.first, !id.isEmpty, id.count <= 128, !id.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
        clusterID = id
        var rest = parts.dropFirst()
        if rest.first == "ns", rest.count >= 2 {
            let ns = rest[rest.startIndex + 1]
            guard KubeNames.isDNSLabel(ns) else { return nil }
            namespace = ns
            rest = rest.dropFirst(2)
        }
        if rest.count == 2, let k = ResourceKind.lookup(rest[rest.startIndex]) {
            let n = rest[rest.startIndex + 1]
            guard KubeNames.isObjectName(n) else { return nil }
            kind = k
            name = n
        } else if !rest.isEmpty {
            return nil
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let v = items.first(where: { $0.name == "view" })?.value, Self.allowedViews.contains(v) { view = v }
        if let c = items.first(where: { $0.name == "container" })?.value, KubeNames.isDNSLabel(c) { container = c }
        previous = items.first { $0.name == "previous" }?.value == "1"
    }

    public var resourceRef: ResourceRef? {
        guard let kind, let name else { return nil }
        return ResourceRef(clusterID: clusterID, kind: kind, namespace: kind.namespaced ? namespace : nil, name: name)
    }

    public static func url(for ref: ResourceRef, view: String? = nil) -> URL? { url(for: ref, view: view, scheme: scheme) }

    static func url(for ref: ResourceRef, view: String?, scheme: String) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "cluster"
        var path = "/\(ref.clusterID)"
        if let ns = ref.namespace { path += "/ns/\(ns)" }
        path += "/\(ref.kind.plural)/\(ref.name)"
        c.path = path
        if let view { c.queryItems = [URLQueryItem(name: "view", value: view)] }
        return c.url
    }
}
