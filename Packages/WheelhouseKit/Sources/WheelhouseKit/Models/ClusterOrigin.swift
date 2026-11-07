import Foundation

/// Where a cluster definition comes from when it is NOT a Keychain or imported cluster (ARCHITECTURE-MAC §4.4).
///
/// `nil` on ``ClusterConfig/origin`` means a Keychain cluster, the iOS meaning. A config with an origin is referenced in place
/// (its secrets stay in the file or come from a plugin), lives only in the Mac-local overlay store and is NEVER written to the
/// iCloud mirror: ``ClusterMetadataStore/save(_:)`` drops it, and `origin` is not part of the config's Codable form.
public enum ClusterOrigin: Codable, Hashable, Sendable {
    /// A Moorings context: the canonical defining file, the context name and the source that found it.
    case kubeconfig(path: String, context: String, sourceID: String)
    /// A Landfall (cloud discovery) cluster.
    case landfall(provider: String, account: String, region: String?)
}
