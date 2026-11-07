import Foundation

public struct SuggestionInput: Sendable, Equatable {
    public var contextName: String?
    public var clusterName: String?
    public var userName: String?
    /// Host of the API server (no scheme or port).
    public var serverHost: String?
    /// Cloud tags, keyed by tag name. Only `env`, `environment` and `stage` are consulted.
    public var cloudTags: [String: String]

    public init(contextName: String? = nil, clusterName: String? = nil, userName: String? = nil, serverHost: String? = nil, cloudTags: [String: String] = [:]) {
        self.contextName = contextName
        self.clusterName = clusterName
        self.userName = userName
        self.serverHost = serverHost
        self.cloudTags = cloudTags
    }
}

public struct EnvironmentSuggestion: Sendable, Equatable {
    public var environment: ClusterEnvironment
    /// "Production", "Staging" or "Development (local)". "Development (local)" is a label on `.development`, not an enum case.
    public var label: String
    public var reasons: [String]
}

/// Suggests an environment for a discovered or imported cluster. The most restrictive match wins (Production, then Staging, then
/// local), and no match returns nil so the person chooses. `ClusterEnvironment.suggested(forName:)` is unchanged (iOS import).
public enum EnvironmentSuggester {
    private static let separators = CharacterSet(charactersIn: "-_./:@")
    private static let stagingTokens: Set<String> = ["stag", "stage", "staging", "stg", "uat", "preprod"]
    private static let localNames: Set<String> = ["minikube", "docker-desktop", "orbstack", "rancher-desktop"]
    private static let localHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]
    private static let tagKeys = ["env", "environment", "stage"]

    /// Lower-cased tokens split on the start, the end and `-`, `_`, `.`, `/`, `:` and `@`.
    static func tokens(_ value: String) -> [String] {
        value.lowercased().components(separatedBy: separators).filter { !$0.isEmpty }
    }

    static func isProductionToken(_ t: String) -> Bool {
        if t == "production" || t == "live" { return true }
        for prefix in ["prod", "prd"] where t.hasPrefix(prefix) {
            let rest = t.dropFirst(prefix.count)
            if rest.allSatisfy(\.isASCIIDigit) { return true }
        }
        return false
    }

    public static func suggest(_ input: SuggestionInput) -> EnvironmentSuggestion? {
        var values: [(source: String, value: String)] = []
        if let v = input.contextName { values.append(("context name", v)) }
        if let v = input.clusterName { values.append(("cluster name", v)) }
        if let v = input.userName { values.append(("user name", v)) }
        if let v = input.serverHost { values.append(("server host", v)) }
        for key in tagKeys { if let v = input.cloudTags[key] { values.append(("tag \(key)", v)) } }

        var production: [String] = [], staging: [String] = [], local: [String] = []
        for (source, value) in values {
            for t in tokens(value) {
                if isProductionToken(t) { production.append("\(source) contains \"\(t)\"") }
                else if stagingTokens.contains(t) { staging.append("\(source) contains \"\(t)\"") }
            }
        }
        for (source, value) in values where source != "server host" && source != "tag env" && source != "tag environment" && source != "tag stage" {
            let lower = value.lowercased()
            if lower.hasPrefix("kind-") || lower.hasPrefix("k3d-") || localNames.contains(lower) { local.append("\(source) \"\(value)\" is a local cluster name") }
        }
        if let host = input.serverHost?.lowercased(), localHosts.contains(host) || host.hasSuffix(".localhost") {
            local.append("server host \"\(host)\" is this Mac")
        }
        if !production.isEmpty { return EnvironmentSuggestion(environment: .production, label: "Production", reasons: production) }
        if !staging.isEmpty { return EnvironmentSuggestion(environment: .staging, label: "Staging", reasons: staging) }
        if !local.isEmpty { return EnvironmentSuggestion(environment: .development, label: "Development (local)", reasons: local) }
        return nil
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
