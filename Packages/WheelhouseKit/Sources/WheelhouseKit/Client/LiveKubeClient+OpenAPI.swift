import Foundation

/// The live OpenAPI v3 read (M7). Only `/openapi/v3` paths are served; the `hash` query of a group-version URL is passed on as a
/// query item (it must not be glued onto the path, which would encode the `?`).
extension LiveKubeClient {
    /// Splits and checks an OpenAPI path. Returns nil for anything but `/openapi/v3[/…][?hash=…]`.
    static func openAPIRequestParts(_ path: String) -> (path: String, query: [(String, String)])? {
        guard let comps = URLComponents(string: path) else { return nil }
        let p = comps.path
        guard p == "/openapi/v3" || p.hasPrefix("/openapi/v3/"), !p.contains(".."), !p.contains("//"), !path.contains("%") else { return nil }
        let items = comps.queryItems ?? []
        guard items.allSatisfy({ $0.name == "hash" }) else { return nil }
        return (p, items.map { ($0.name, $0.value ?? "") })
    }

    public func openAPIDocument(path: String) async throws -> Data {
        guard let parts = Self.openAPIRequestParts(path) else { throw KubeError.unsupported("Only OpenAPI v3 documents can be read this way.") }
        return try await perform(try makeRequest(path: parts.path, query: parts.query, timeout: 60))
    }
}
