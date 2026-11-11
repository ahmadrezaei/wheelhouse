import Foundation

/// One Helm chart found on Artifact Hub.
public struct ArtifactHubPackage: Sendable, Hashable, Identifiable {
    public var name: String
    public var version: String
    public var appVersion: String?
    public var summary: String?
    public var repositoryName: String
    public var repositoryURL: String
    public var id: String { "\(repositoryName)/\(name)" }
}

/// Artifact Hub search (ARCHITECTURE-MAC section 5.3). It is the only third-party request Chart Room makes: off by default, a single GET,
/// no identifiers. This type only builds the URL and reads the answer; the app makes the request.
public enum ArtifactHub {
    public static let host = "artifacthub.io"
    public static let maxResults = 30

    /// `GET https://artifacthub.io/api/v1/packages/search?kind=0&ts_query_web=<q>`. nil for an empty query.
    public static func searchURL(query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100 else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/v1/packages/search"
        components.queryItems = [URLQueryItem(name: "kind", value: "0"), URLQueryItem(name: "ts_query_web", value: trimmed),
                                 URLQueryItem(name: "limit", value: String(maxResults))]
        return components.url
    }

    /// Reads `{"packages": [...]}` (or a bare array, as older versions answered). Entries without a name or a repository are skipped, and
    /// only http(s) and oci repository URLs are kept.
    public static func decode(_ data: Data) -> [ArtifactHubPackage] {
        guard let json = try? JSONValue.parse(data) else { return [] }
        let items = json["packages"]?.arrayValue ?? json.arrayValue ?? []
        return items.prefix(maxResults).compactMap { item in
            guard let name = item["name"]?.stringValue, !name.isEmpty,
                  let repoName = item.value(at: "repository.name")?.stringValue, !repoName.isEmpty,
                  let repoURL = item.value(at: "repository.url")?.stringValue, ["https://", "http://", "oci://"].contains(where: repoURL.hasPrefix) else { return nil }
            return ArtifactHubPackage(name: name, version: item["version"]?.stringValue ?? "", appVersion: item["app_version"]?.stringValue,
                                      summary: item["description"]?.stringValue, repositoryName: repoName, repositoryURL: repoURL)
        }
    }
}
