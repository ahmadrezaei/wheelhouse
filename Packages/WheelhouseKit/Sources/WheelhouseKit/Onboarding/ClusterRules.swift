import Foundation

public extension ClusterConfig {
    /// Production clusters must use https: a bearer token over plain HTTP is readable by anyone on the path.
    var violatesHTTPProductionRule: Bool { isProduction && server.scheme?.lowercased() == "http" }
}
