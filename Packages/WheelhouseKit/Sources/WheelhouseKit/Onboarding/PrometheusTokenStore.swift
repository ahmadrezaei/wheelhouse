import Foundation

/// Optional bearer token for a user-supplied Prometheus URL. `ClusterSecrets` has no field for it, so it lives in its own Keychain item.
public enum PrometheusTokenStore {
    private static let service = "app.wheelhouse.prometheus"
    public static func load(clusterID: ClusterID) -> String? {
        guard let data = try? KeychainAccess.read(service: service, account: clusterID) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    /// Returns false when the Keychain refused the write.
    @discardableResult
    public static func save(_ token: String?, clusterID: ClusterID, synchronizable: Bool) -> Bool {
        let t = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if t.isEmpty { return (try? KeychainAccess.delete(service: service, account: clusterID)) != nil }
        return (try? KeychainAccess.write(Data(t.utf8), service: service, account: clusterID, synchronizable: synchronizable)) != nil
    }
    public static func delete(clusterID: ClusterID) { try? KeychainAccess.delete(service: service, account: clusterID) }
    /// Re-saves an existing token under a new iCloud-sync setting (add the new variant first, then remove the old one).
    @discardableResult
    public static func setSynchronizable(_ synchronizable: Bool, clusterID: ClusterID) -> Bool {
        guard let token = load(clusterID: clusterID), !token.isEmpty else { return true }
        return (try? KeychainAccess.write(Data(token.utf8), service: service, account: clusterID, synchronizable: synchronizable)) != nil
    }
}
