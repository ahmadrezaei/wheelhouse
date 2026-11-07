import Foundation

/// Optional bearer token for a user-supplied Prometheus URL. `ClusterSecrets` has no field for it, so it lives in its own Keychain item.
public enum PrometheusTokenStore {
    private static let service = "app.wheelhouse.prometheus"
    /// True when ANY variant holds bytes that are not a UTF-8 token (written in a format a newer app understands). Never overwritten or deleted.
    static func isUnreadable(clusterID: ClusterID, in backend: any KeychainBackend = SystemKeychain()) -> Bool {
        // Fail closed: if the Keychain can't be read, treat the item as not ours to replace or delete.
        guard let all = try? KeychainAccess.readAll(service: service, account: clusterID, in: backend) else { return true }
        return all.contains { String(data: $0, encoding: .utf8) == nil }
    }
    public static func load(clusterID: ClusterID) -> String? {
        guard let data = try? KeychainAccess.read(service: service, account: clusterID) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    /// Returns false when the Keychain refused the write.
    @discardableResult
    public static func save(_ token: String?, clusterID: ClusterID, synchronizable: Bool) -> Bool {
        save(token, clusterID: clusterID, synchronizable: synchronizable, in: SystemKeychain())
    }
    static func save(_ token: String?, clusterID: ClusterID, synchronizable: Bool, in backend: any KeychainBackend) -> Bool {
        if isUnreadable(clusterID: clusterID, in: backend) { return true }   // left alone: not ours to replace
        let t = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if t.isEmpty { return (try? KeychainAccess.delete(service: service, account: clusterID, in: backend)) != nil }
        return (try? KeychainAccess.write(Data(t.utf8), service: service, account: clusterID, synchronizable: synchronizable, in: backend)) != nil
    }
    public static func delete(clusterID: ClusterID) { delete(clusterID: clusterID, in: SystemKeychain()) }
    static func delete(clusterID: ClusterID, in backend: any KeychainBackend) {
        if isUnreadable(clusterID: clusterID, in: backend) { return }
        try? KeychainAccess.delete(service: service, account: clusterID, in: backend)
    }
}
